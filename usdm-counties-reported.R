# update.packages(repos = "https://cran.rstudio.com/",
#                 ask = FALSE)

install.packages("pak",
                 repos = "https://cran.rstudio.com/")

# installed.packages() |>
#   rownames() |>
#   pak::pkg_install(upgrade = TRUE,
#                  ask = FALSE)

pak::pak(
  c(
    "arrow?source",
    "sf?source",
    "curl",
    "tidyverse",
    "tigris",
    "rmapshaper",
    "furrr",
    "future.mirai"
  )
)

library(magrittr)
library(tidyverse)
library(sf)
library(arrow)
library(furrr)
library(future.mirai)

sf::sf_use_s2(TRUE)

dir.create(
  file.path("data", "usdm"),
  recursive = TRUE,
  showWarnings = FALSE
)

## Load the FSA LFP county boundary data
if(!file.exists("data/fsa-lfp-counties.parquet")){
  sf::read_sf(
    "https://sustainable-fsa.github.io/fsa-lfp-counties/fsa-lfp-counties.parquet"
  ) %>%
    dplyr::transmute(STATEFP = StateFIPS,
                     COUNTYFP = stringr::str_sub(CountyFIPS, start = 3L)) %>%
    dplyr::left_join(
      tigris::counties(cb = TRUE, year = 2020) %>%
        sf::st_drop_geometry()
    ) %>%
    dplyr::mutate(Area = sf::st_area(geometry)) %>%
    dplyr::select(STATEFP, 
                  State = STATE_NAME, 
                  COUNTYFP, 
                  County = NAME, 
                  CountyLSAD = NAMELSAD,
                  Area) %T>%
    sf::write_sf(
      "data/fsa-lfp-counties.parquet",
      driver = "Parquet",
      layer_options = c("COMPRESSION=BROTLI",
                        "GEOMETRY_ENCODING=GEOARROW",
                        "WRITE_COVERING_BBOX=NO"),
    )
}

counties <-
  sf::read_sf("data/fsa-lfp-counties.parquet") %>%
  sf::st_drop_geometry() |>
  dplyr::transmute(
    FIPS = paste0(STATEFP, COUNTYFP),
    STATEFP, 
    State, 
    COUNTYFP, 
    County, 
    CountyLSAD
  )

states <-
  sf::read_sf(
    "https://sustainable-fsa.github.io/fsa-lfp-counties/fsa-lfp-counties.parquet"
  ) %$%
  StateAbbr %>%
  unique() %>%
  sort() %>%
  paste(collapse = ",")


## Get the current list of USDM dates
usdm_get_dates <-
  function(as_of = lubridate::today()){
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
        readr::read_csv(show_col_types = FALSE) |>
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
        dplyr::select(STATEFP, State, COUNTYFP, County, CountyLSAD, 
                      usdm_date, usdm_class, usdm_percent) |>
        dplyr::arrange(STATEFP, COUNTYFP, usdm_date, usdm_class) |>
          arrow::write_parquet(sink = outfile,
                               version = "latest",
                               compression = "zstd",
                               use_dictionary = TRUE)
    }
  )

plan(sequential)

## Create a single parquet output, for simplicity
list.files("data/usdm",
           recursive = TRUE,
           full.names = TRUE) %>%
  purrr::map_dfr(arrow::read_parquet) %>%
  dplyr::arrange(STATEFP, COUNTYFP, usdm_date, usdm_class) %>%
  arrow::write_parquet(sink = "usdm-counties-reported.parquet",
                       version = "latest",
                       compression = "zstd",
                       use_dictionary = TRUE)

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

# Knit the readme
rmarkdown::render("README.Rmd")
