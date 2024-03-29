# Load Library----
library("tidyverse", warn.conflicts = F)
library("janitor")
library("kableExtra")
library("AMR")
library("readxl")
library("plotly")
# library("Hmisc")

# Load functions----
source("code/Functions.R", knitr::knit_global())
# Month-----
month <- data.frame(collection_date_in_month = factor(
  c("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"),
  levels = month.abb
))

# Notifiable organisms in MoH----
org_in_hos <- c(
  "Klebsiella pneumoniae",
  "Acinetobacter",
  "Burkholderia cepacia",
  "Stenotrophomonas maltophilia",
  "Pseudomonas aeruginosa",
  "Pseudomonas",
  "Non-fermenting gram negative rods",
  "Staphylococcus aureus"
)

# Contamination organism----
cont_org_list <- c(
  "Coagulase Negative Staphylococcus",
  "Corynebacterium",
  "Streptococcus viridans, alpha-hem.",
  "Micrococcus",
  "Bacillus"
)

# set up specimen color
specimen_color <- c("Blood Culture" = "#F7766D", # blood red
                    "Pus" = "#D1B087", # pus yellow-gray
                    "Urine" = "#F7A62C", 
                    "Body Fluid" = "#C3CDF6",
                    "CSF" = "#FFCCCC",
                    "Sputum" = "#B4AC54",
                    "Stool" = "#BBBBBB",
                    "Genital swab" = "#F76ACD",
                    "Throat swab" = "#BE3737",
                    "Tissue" = "#DC376F"
)

# Load dictionary----
dic <- list.files(path = "data",
                   pattern = "^[Dd]ic.*(\\s)?.xls(x)?",
                   full.names = T) %>%
        read_excel(sheet = "hospital", col_names = T, trim_ws = T)

dic <- dic %>%
  select(parameter = Parameter, full_name = `Full name`) %>%
  pivot_wider(names_from = parameter, values_from = full_name) %>%
  clean_names() %>%
  mutate(
    short_name = case_when(
      hospital_name == "Siem Reap Provincial Referral Hospital" ~ "SRH",
      hospital_name == "Kampong Cham Provincial Referral Hospital" ~ "KCM",
      hospital_name == "Battambang Provincial Referral Hospital" ~ "BTB",
      hospital_name == "Takeo Provincial Referral Hospital" ~ "TKV",
      hospital_name == "All laboratories" ~ "All"
    ),
    hospital_name = recode(hospital_name,
      "All laboratories" = "Siem Reap, 
      Takeo, Battambang and Kampong Cham Provincial Referral Hospital"
    )
  ) %>%
  mutate_at(vars(contains("date")), as.Date, format = "%d-%m-%Y")


# Load data----
data <- list.files(path = "data", pattern = ".*[Bb]ac.*port.*.xls(x)?", full.names = T) %>%
                   purrr::discard(file_name, .p = ~ stringr::str_detect(., "~")) %>%
                   map_df(read_file) %>%
                   mutate(sex = factor(sex)) %>%
                   format_date()

# Filter based on lab name
data <- data %>% 
  filter(lab_name == ifelse(dic$short_name == "All", lab_name, dic$short_name))


# Filter based on date
data <- data %>% 
  mutate(col_date = as.Date(collection_date)) %>% 
  arrange(col_date) %>% 
  filter(col_date >= dic$start_date, 
         col_date <= ifelse(dic$end_date >= max(col_date, na.rm = T),
                             max(col_date, na.rm = T),
                             dic$end_date
    )) %>% select(-col_date) 

# Recode specimen and mutate column collection_date_in month
data <- data %>% 
          mutate(collection_date_in_month = factor(format(collection_date, "%b"),
                                                    levels = month.abb),
          sample = recode( sample,
                           "Pus aspirate" = "Pus",
                           "Pus swab"     = "Pus",
                           "Swab‐genital" = "Genital swab"
                         )
                ) 


# Deduplicate data
data <- data %>% 
  distinct(patient_id, lab_id, collection_date, sample, results, .keep_all = T)

# Reject specimen
reject_spe <- data %>% 
  select( patient_id, lab_id, collection_date, sample, results, comment, reject_comment) %>%
  distinct(patient_id, lab_id, collection_date, sample, results, .keep_all = T)

# Clean organism name
data <- data %>% 
  clean_org(., results)

# Age group
data <- data %>%
  mutate(
    unit = str_extract(age, pattern = "\\D+"),
    age = str_extract(age, pattern = "\\d+"),
    age = case_when(
      unit == "y" ~ as.numeric(age) * 365,
      unit == "m" ~ as.numeric(age) * 30,
      TRUE ~ as.numeric(age)
    )
  ) %>%
  relocate(unit, .after = age)


# Convert antibiotic name to standardize
data <- data %>%
  rename_with(as.ab, amikacin:vancomycin) %>%
  mutate_if(is.rsi.eligible, as.rsi)


# Finding last month
last_month <- data %>%
  distinct(collection_date_in_month)

# Joint ward data----
ward <- list.files( path = "data",
                    pattern = "^[Dd]ic.*.xls(x)?",
                    full.names = T
        ) %>%
        read_excel(
          sheet = "ward",
          col_names = T,
          trim_ws = T
        )

data <-
  left_join(data, ward, by = c("sample_source" = "ward_from_Camlis")) %>%
  mutate(sample_source = coalesce(new_ward_in_english, sample_source)) %>%
  select(-new_ward_in_english, -Comment)

rm(ward)

# Deduplication----

# deduplicare by patient ID
dedup_by_pid <- data %>%
  arrange(collection_date) %>%
  distinct(patient_id, .keep_all = T)

# deduplicare by patient id, lab id and sample type
dedup_by_id_stype <- data %>%
  arrange(collection_date) %>%
  distinct(patient_id, lab_id, sample, .keep_all = T)


# Blood culture first isolate----
bc_first_isolate <- data %>%
  filter(
    sample == "Blood Culture",
    !results %in% c(cont_org_list, "No growth")
  ) %>%
  mutate(mo = as.mo(results, info = F)) %>%
  filter_first_isolate(
    episode_day = 30,
    col_patient_id = "patient_id",
    col_date = "collection_date",
    col_mo = "results",
    info = F
  ) %>%
  eucast_rules(
    col_mo = "mo",
    rules = "all",
    version_expertrules = 3.3,
    info = F
  )

bc_cont_deduplicate <-
  data %>%
  filter(sample == "Blood Culture", results %in% c(cont_org_list)) %>%
  distinct(lab_id, results, .keep_all = T)

# Possible HAI
HAI <- data %>% # from dataset select only notifiable organism
  select(
    patient_id,
    sample,
    collection_date,
    admission_date,
    results,
    collection_date_in_month
  ) %>%
  filter(sample == "Blood Culture", results %in% org_in_hos) %>%
  mutate(HAI = as.numeric(collection_date - admission_date)) %>%
  arrange(collection_date_in_month) %>%
  distinct(patient_id, .keep_all = T)

# Clean comment----
comment <- data %>%
  select(lab_name, sample, results, comment) %>%
  filter(sample == "Blood Culture", !is.na(comment)) %>%
  mutate(
    comment = str_replace_all(str_to_lower(comment), 
                              c("\\bone" = "1",
                                "\\btwo" = "2",
                                "\\bthree" = "3",
                                "\\bfour" = "4",
                                "\\bfive" = "5",
                                "\\bsix" = "6",
                                "\\bseven" = "7",
                                "\\beight" = "8",
                                "\\bnine" = "9",
                                "\\bzero" = "0"
                              )),
    bottle_pos = str_extract(comment, pattern = "\\d\\s?[oO]f\\s?\\d"),
    day_growth = str_extract(comment, "\\d(?=\\s?day)|(?<=[ys]\\s?)\\d")
    
  )

# Critical results detection
critical_result <- data %>%
  filter(sample == "Blood Culture", !is.na(comment), results != "No growth") %>%
  distinct(patient_id, results, .keep_all = T) %>%
  select(comment) %>%
  mutate(
    call = str_detect(str_to_lower(comment),
                      "call[ed]?|phon[ed]?|dr(\\.+)?|clinician[s]?"
    ),
    total = n()
  ) %>%
  filter(call == T) %>%
  mutate(p = round_half_up(n() * 100 / total)) %>%
  select(total, p) %>%
  distinct()

# TAT
TAT <- data %>%
  select(lab_name, patient_id, collection_date, admission_date, sample, results, comment) %>%
  filter(
    !is.na(results),
    sample == "Blood Culture",
    !is.na(comment),
    !results %in% c("No growth")
  ) %>%
  distinct(patient_id, results, .keep_all = T) %>%
  mutate(
    comment_by = str_extract(str_to_lower(comment),
      pattern = "(\\.*)?(call[ed]?|phon[ed]?)(.*)"
    ),
    comment_by = str_replace(comment_by,
      pattern = "(die[d]|dead) (on)? \\d+[/ ,.-]\\d+[/ ,.-]\\d+", ""
    ),
    date = str_extract(comment_by, pattern = "\\d+[/ ,.-]\\d+[/ ,.-]\\d+"),
    time = str_extract(comment_by, pattern = "\\d+(\\s)?[ :.;](\\s)?\\d+(\\s)?([AaPp][Mm])?")
  ) %>%
  filter(!is.na(comment_by)) %>%
  mutate(primary_report = lubridate::dmy_hm(paste(date, time), quiet = TRUE))

