# update.packages(repos = "https://cran.rstudio.com/",
#                 ask = FALSE)
# 
# install.packages("pak",
#                  repos = "https://mac.r-project.org")
# 
# options("pkg.cran_mirror" = "https://mac.r-project.org")
# 
# # installed.packages() |>
# #   rownames() |>
# #   pak::pkg_install(upgrade = TRUE,
# #                  ask = FALSE)
# 
# pak::pak(
#   c(
#     "arrow?source",
#     "sf?source",
#     "curl",
#     "tidyverse",
#     "tigris",
#     "rmapshaper",
#     "furrr",
#     "future.mirai",
#     "httr2"
#   )
# )

library(magrittr)
library(tidyverse)
library(sf)
library(arrow)
library(furrr)
library(future.mirai)

source("R/s3-archive.R")
s3_preflight()
s3_bucket_name <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix      <- Sys.getenv("S3_PREFIX", unset = "usdm-counties-reported")
## Pull prior archive state so incremental guards see existing outputs
s3_pull(s3_bucket_name, paste0(s3_prefix, "/data"), "data")

## Heal weeks previously written empty by the silent-empty-API bug: delete
## zero-row weekly parquets so they are refetched below (the mirror push
## with delete = TRUE propagates the repair to S3).
list.files(file.path("data", "usdm"), full.names = TRUE) %>%
  purrr::walk(
    function(f){
      if(nrow(arrow::read_parquet(f)) == 0L){
        gate_skip(paste0("Purging empty weekly parquet ", f, " for refetch."))
        file.remove(f)
      }
    })

sf::sf_use_s2(TRUE)

dir.create(
  file.path("data", "usdm"),
  recursive = TRUE,
  showWarnings = FALSE
)

## Load the FSA LFP county boundary data
if(!file.exists("data/fsa-lfp-counties.parquet")){
  sf::read_sf(
    "https://data.sustainable-fsa.com/fsa-lfp-counties/fsa-lfp-counties.parquet"
  ) %>%
    dplyr::transmute(STATEFP = StateFIPS,
                     COUNTYFP = stringr::str_sub(CountyFIPS, start = 3L)) %>%
    dplyr::left_join(
      tigris::counties(cb = TRUE, year = 2020) %>%
        sf::st_drop_geometry()
    ) %>%
    dplyr::mutate(Area = sf::st_area(geometry)) %>%
    dplyr::select(GEOID,
                  STATEFP, 
                  State = STATE_NAME, 
                  COUNTYFP, 
                  County = NAME, 
                  CountyLSAD = NAMELSAD,
                  Area) %T>%
    sf::write_sf(
      "data/fsa-lfp-counties.parquet",
      driver = "Parquet",
      layer_options = c("COMPRESSION=ZSTD",
                        "COMPRESSION_LEVEL=13"),
      delete_dsn = TRUE
    )
}

counties <-
  sf::read_sf("data/fsa-lfp-counties.parquet") %>%
  sf::st_drop_geometry() |>
  dplyr::transmute(
    FIPS = GEOID,
    STATEFP, 
    State, 
    COUNTYFP, 
    County, 
    CountyLSAD
  )

states <-
  sf::read_sf(
    "https://data.sustainable-fsa.com/fsa-lfp-counties/fsa-lfp-counties.parquet"
  ) %$%
  StateAbbr %>%
  unique() %>%
  sort() %>%
  paste(collapse = ",")


## Get the current list of USDM dates
usdm_get_dates <-
  function(as_of = lubridate::today("America/Denver")){
    as_of %<>%
      lubridate::as_date()
    
    usdm_dates <-
      seq(lubridate::as_date("20000104"), lubridate::today(), "1 week")
    
    usdm_dates <- usdm_dates[(as_of - usdm_dates) >= 2]
    
    return(usdm_dates)
  }

plan(mirai_multisession)

usdm_get_dates() %>%
  tibble::tibble(Date = .) %>%
  dplyr::mutate(
    outfile = file.path("data", "usdm", 
                        paste0("USDM_",Date,".parquet"))
  ) %>%
  dplyr::filter(!file.exists(outfile)) %>%
  furrr::future_pwalk(
    .f = function(Date,
                  outfile, 
                  ...){
      
      Date %<>%
        lubridate::stamp_date("1/31/2000",
                              quiet = TRUE)()
      
      dat <-
        httr2::url_modify(
          "https://usdmdataservices.unl.edu",
          path =
            file.path(
              "api",
              "CountyStatistics",
              "GetDroughtSeverityStatisticsByAreaPercent"
            ),
          query =
            list(
              aoi =
                states,
              startdate = Date,
              enddate = Date,
              statisticsType = "2"
            )) |>
        readr::read_csv(show_col_types = FALSE)
      
      ## Freshness gate: zero rows is never legitimate (national area-percent
      ## stats always include nonzero None rows) — the API just doesn't have
      ## this week yet. Leave the week unwritten so a later run retries it.
      if(nrow(dat) == 0L){
        gate_skip(paste0("NDMC DataServices returned no rows for ", Date,
                         "; leaving week unwritten for retry."))
        return(invisible(NULL))
      }
      
      dat |>
        dplyr::transmute(FIPS,
                         usdm_date = lubridate::ymd(MapDate),
                         dplyr::across(None:D4)) |>
        tidyr::pivot_longer(None:D4,
                            names_to = "usdm_class",
                            values_to = "usdm_percent") |>
        dplyr::filter(usdm_percent != 0) |>
        dplyr::left_join(counties,
                         by = join_by(FIPS)) |>
        dplyr::mutate(
          usdm_class = 
            factor(usdm_class,
                   levels = c("None", paste0("D", 0:4)),
                   ordered = TRUE),
          usdm_percent = usdm_percent/100
        ) |>
        dplyr::select(GEOID = FIPS, STATEFP, State, COUNTYFP, County, CountyLSAD, 
                      usdm_date, usdm_class, usdm_percent) |>
        dplyr::arrange(GEOID, usdm_date, usdm_class) |>
        arrow::write_parquet(sink = outfile,
                             version = "latest",
                             compression = "zstd",
                             compression_level = 13,
                             use_dictionary = TRUE)
    }
  )

plan(sequential)

## Create a single parquet output, for simplicity
usdm_counties_reported <-
  list.files("data/usdm",
             recursive = TRUE,
             full.names = TRUE) %>%
  purrr::map_dfr(arrow::read_parquet) %>%
  dplyr::arrange(STATEFP, COUNTYFP, usdm_date, usdm_class)

usdm_counties_reported %>%
  arrow::write_parquet(sink = "usdm-counties-reported.parquet",
                       version = "latest",
                       compression = "zstd",
                       compression_level = 13,
                       use_dictionary = TRUE)

## Browser-optimized JSON mirror of the weekly worst (max) USDM class per
## county, for web maps: the full area-percent detail stays in the parquet;
## the browser needs only "how bad was this county this week." One fixed-
## width string per county — one character per USDM Tuesday, '.' where the
## county is absent from that week's vintage — is ~10x smaller raw than
## parallel arrays and decodes with a single charCodeAt. Worst class means
## max(usdm_class) over every row present, no percent threshold, matching
## fsa-lfp-eligibility-derived: any nonzero-area sliver counts.
## The schema is a frozen contract — add fields; never rename or reorder
## existing ones without bumping "usdm-max-class/1"; the dataset field says
## which of the three USDM county archives a payload is.
##
## usdm-max-class/1 decode:
##   const d = await (await fetch('usdm-counties-reported.json')).json();
##   // week j (0-based, j < d.weeks) is the Tuesday d.week0 + 7*j days:
##   const t = Date.parse(d.week0) + j * 7 * 86400000;
##   // worst USDM class for county i (d.counties[i], the county GEOID — a
##   // 5-char FIPS code; the nine Connecticut planning-region GEOIDs carry
##   // an empty county name) at week j:
##   const ch = d.series[i][j];
##   if (ch === '.') { /* county not in this week's archive vintage */ }
##   else label = d.classes[ch.charCodeAt(0) - 48];   // 'None','D0'..'D4'
##   // display: d.county_names[i] ('' = archive has no name), d.state_names[i]
##   // integrity: total non-'.' chars across d.series === d.n
web_classes <- c("None", paste0("D", 0:4))
web_week0 <- lubridate::as_date("2000-01-04")

stopifnot(identical(levels(usdm_counties_reported$usdm_class), web_classes))
web_max <-
  usdm_counties_reported %>%
  dplyr::transmute(
    county = GEOID,
    usdm_date,
    class = as.integer(usdm_class) - 1L
  ) %>%
  dplyr::group_by(county, usdm_date) %>%
  dplyr::summarise(class = max(class), .groups = "drop") %>%
  dplyr::arrange(county, usdm_date)

## The week axis is the unbroken Tuesday grid; a county-week the archive
## does not carry becomes '.', never an imputed value.
stopifnot(min(web_max$usdm_date) == web_week0,
          all(as.integer(web_max$usdm_date - web_week0) %% 7L == 0L))
web_weeks <- as.integer(max(web_max$usdm_date) - web_week0) %/% 7L + 1L

## Radix sort is the C locale, so the file is byte-identical whatever
## locale the runner happens to be in.
web_counties <- sort(unique(web_max$county), method = "radix")

web_grid <- matrix(".", nrow = length(web_counties), ncol = web_weeks)
web_grid[cbind(match(web_max$county, web_counties),
               as.integer(web_max$usdm_date - web_week0) %/% 7L + 1L)] <-
  as.character(web_max$class)
web_series <-
  vapply(seq_along(web_counties),
         function(i) paste(web_grid[i, ], collapse = ""),
         character(1))

## The digit-and-dot strings must reconstruct the max-class table exactly;
## a lossy encoding would be invisible in the browser.
stopifnot(identical(
  tibble::tibble(
    county = rep(web_counties, each = web_weeks),
    usdm_date = rep(web_week0 + 7L * (seq_len(web_weeks) - 1L),
                    times = length(web_counties)),
    class = unlist(strsplit(web_series, "", fixed = TRUE), use.names = FALSE)
  ) %>%
    dplyr::filter(class != ".") %>%
    dplyr::mutate(class = as.integer(class)),
  web_max
))

## Display names for the dictionary only: each key's name as recorded at
## its most recent week.
web_names <-
  usdm_counties_reported %>%
  dplyr::transmute(county = GEOID,
                   usdm_date, County, State) %>%
  dplyr::group_by(county) %>%
  dplyr::slice_max(usdm_date, n = 1, with_ties = FALSE) %>%
  dplyr::ungroup()

## The nine Connecticut planning regions (09110-09190) never joined the
## tigris 2020 county table, so their names are NA: emit "" for the county
## and recover the state from the GEOID prefix via the county boundary
## table. That table, not the archive, is the lookup: NDMC reports
## Connecticut only as planning regions, so no row of the archive itself
## ever carries STATEFP "09".
web_state_lookup <-
  counties %>%
  dplyr::filter(!is.na(State)) %>%
  dplyr::distinct(STATEFP, State)
web_names <-
  web_names %>%
  dplyr::mutate(
    State = dplyr::coalesce(
      State,
      web_state_lookup$State[match(stringr::str_sub(county, 1L, 2L),
                                   web_state_lookup$STATEFP)]),
    County = tidyr::replace_na(County, ""))

stopifnot(!anyDuplicated(web_names$county),
          nrow(web_names) == length(web_counties),
          !anyNA(web_names$County), !anyNA(web_names$State))
web_names <- web_names[match(web_counties, web_names$county), ]

jsonlite::write_json(
  list(
    schema = jsonlite::unbox("usdm-max-class/1"),
    dataset = jsonlite::unbox("usdm-counties-reported"),
    license = jsonlite::unbox("CC0-1.0"),
    classes = web_classes,
    week0 = jsonlite::unbox(format(web_week0)),
    weeks = jsonlite::unbox(web_weeks),
    counties = web_counties,
    county_names = web_names$County,
    state_names = web_names$State,
    n = jsonlite::unbox(nrow(web_max)),
    series = web_series
  ),
  "usdm-counties-reported.json",
  auto_unbox = FALSE, digits = NA
)

## Create directory listing infrastructure
generate_tree_flat <- function(
    data_dir = "data", 
    output_file = file.path("manifest.json")) {
  
  all_entries <- 
    fs::dir_ls(data_dir, recurse = TRUE, all = TRUE, type = "file") |>
    stringr::str_subset("(^|/)[.][^/]+", negate = TRUE)
  
  entries <- list()
  
  for (entry in all_entries) {
    rel_path <- fs::path_rel(entry, start = ".")
    info <- fs::file_info(entry)
    is_dir <- fs::is_dir(entry)
    entry_data <- list(
      path = as.character(rel_path),
      size = if (is_dir) "-" else info$size,
      mtime = if (is_dir) "-" else format(info$modification_time, "%Y-%Om-%d %H:%M:%S")
    )
    entries[[length(entries) + 1]] <- entry_data
  }
  
  # Sort by path
  entries <- entries[order(sapply(entries, function(x) x$path))]
  
  jsonlite::write_json(entries, output_file, pretty = TRUE, auto_unbox = TRUE)
  message("✅ Wrote ", length(entries), " entries to ", output_file)
}

# Generate the flat index
generate_tree_flat()

## ---- Publish to S3 ---------------------------------------------------
s3_push(s3_bucket_name, paste0(s3_prefix, "/data"), "data", delete = TRUE)
s3_put(s3_bucket_name, paste0(s3_prefix, "/usdm-counties-reported.parquet"),
       "usdm-counties-reported.parquet",
       content_type = "application/vnd.apache.parquet",
       cache_control = "max-age=3600")
s3_put(s3_bucket_name, paste0(s3_prefix, "/usdm-counties-reported.json"),
       "usdm-counties-reported.json",
       content_type = "application/json",
       cache_control = "max-age=3600")
s3_put(s3_bucket_name, paste0(s3_prefix, "/manifest.json"), "manifest.json",
       content_type = "application/json",
       cache_control = "max-age=3600")
s3_verify(s3_bucket_name, paste0(s3_prefix, "/data"), "data",
          allow_extra = character(0))
s3_write_manifest(s3_bucket_name, s3_prefix)
cf_invalidate(c(paste0("/", s3_prefix, "/usdm-counties-reported.parquet"),
                paste0("/", s3_prefix, "/usdm-counties-reported.json"),
                paste0("/", s3_prefix, "/manifest.json"),
                paste0("/", s3_prefix, "/_manifest.txt")))

# ---- Render the README ----
# Regenerates README.md and the example map from the freshly updated
# archive; the workflow commits these (and only these) back to git.
cf_wait_manifest("https://data.sustainable-fsa.com/usdm-counties-reported/manifest.json",
                 "manifest.json")
rmarkdown::render("README.Rmd")
