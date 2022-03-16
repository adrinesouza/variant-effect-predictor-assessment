# Variant effect predictor assessment pipeline

This GitHub repository contains the computational analysis pipeline used in the manuscript "Assessing computational variant effect predictors with a large prospective cohort" (in preparation).

**Please note**, this repository does NOT contain raw data from the UK Biobank as they are available upon application. Please visit the [UK Biobank website](https://www.ukbiobank.ac.uk/) to apply for data access.

## Install

To install the pipeline, first make sure your R version is at least R 4.0. You can check by typing the following into your R console:

```{r}
R.version()$major
```

Next, clone the repository by typing the following into your command line interface:
```
git clone https://github.com/kvnkuang/variant-effect-predictor-assessment
```

## Confiugre the running parameters

The [config.yaml](config.yaml) file lists all the running parameters that you can congifure.

Here we document all parameters supported by the pipeline and their functions.

| Parameter | Description | Default Value |
| --- | --- | --- |
| gene_list| A file with all the genes used in the study.<br>*See the sample file referred to by the default value for format.* | [common/genes.csv](common/genes.csv) |
| phenotype_list | A file with all phenotypes (traits) used in the study. <br>*See the sample file referred to by the default value for format.* | [common/phenotypeDescriptions.csv](common/phenotypeDescriptions.csv) |
| rscript_path | The path to the RScript executable. | Rscript.exe |
| occurance_cutoff | The occurance cutoff used in the study.<br>*See the Material & Method section of the manuscript for detail.* | 10 |
| bootstrap_iterations | The number of iterations for the bootstrap resampling process.<br>*See the Material & Method section of the manuscript for detail.* | 1000 |
| all_variants_path | The filename of the input file with all variants in a given gene. | merged_hgvs.csv |
| unique_variants_path | The filename of the input file with unique variants and computational predictor scores for a given gene. | allv_withweights.csv |
| withdraw_eids_path | A file with all the participants who have withdrawn their participation in the UK Biobank.<br>*See the sample file referred to by the default value for format. Replace "<withdrawn_eidx>" in the sample file with actual EIDs. We are unable to provide real EIDs due to UK Biobank's data sharing restrictions.* | [common/withdraws.csv](common/withdraws.csv) |
| db_connect_path | A file with connection credentials to a local database where all UK Biobank variants are stored.<br>*See the sample file referred to by the default value for format. We are unable to provide access to the real database, but please see below ("Set up UK Biobank database") for the database schema that you can use to set up the database yourself with UK Biobank data.* | [db_connect.yaml](db_connect.yaml) |
| variant_predictors | A list of variant effect predictors used in the study.<br>*Format: [predictor name]: [predictor column name in unique variants file (unique_variants_path)]* | *!incomplete list!*<br>VARITY: VARITY_R<br>PolyPhen-2: Polyphen2_selected_HVAR_score<br>... |

## Set up a local UK Biobank phenotype database

Using the phenotypes requested from the UK Biobank, set up a local UK Biobank phenotype database that the pipeline can use to query relevant phenotype information.

**Please note**, we are not permitted to provide any access to a database containing UK Biobank data. Instead, we provide this Data Definition Language (DDL) snippet that can be used to set up a database compatible with this analysis pipeline.

This snippnet is tested for MariaDB version 5.5 and should work for any modern MySQL and MariaDB instances.

```
create table phenotypes
(
	eid varchar(10) null,
	pid varchar(50) null,
	measurement text null,
	array_index smallint null
);

create index phenotype_pid_index
	on phenotypes (pid);

create index phenotypes_eid_index
	on phenotypes (eid);

create index phenotypes_eid_pid_index
	on phenotypes (eid, pid);
```

Here we describe the four columns defined in the above DDL snippet.

| Column Name | Description |
| --- | --- |
| eid | The unique ID assigned to each UK Biobank participant |
| pid | The unique ID assigned to each phenotype (trait) in the UK Biobank.<br>This must match with the `field_id`s in phenotype files defined in the config file above. |
| measurement | The actual measurement of the phenotype. |
| array_index | When a phenotype has multiple measurements, this index records the position of each measurement. |

## Run the pipeline

To run the pipeline, type the following line into your command line interface:

```
Rscript main.R <configuration-file> <log-dir>
```

There are two required arguments:
1. **configuration-file:** the path to configuration file (e.g. config.yaml)
2. **log-dir:** the directory to the log files (e.g. logs/)

## Contact us

If you have any feedback, suggestions or questions, please reach out via [email](mailto:kvn.kuang@mail.utoronto.ca) or open an issue on github.
