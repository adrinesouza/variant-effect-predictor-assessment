library(data.table)
library(ggplot2)
library(stringr)
library(ggtext)
library(forcats)
library(Rmisc)
library(gridExtra)
library(fs)
library(dplyr)
library(grid)
library(doParallel)
library(parallel)

# Set arguments if not passed in already as config
GENE = tolower(config$gene)
UNIQUE_VARIANTs_PATH = config$unique_variants_path
VARIANT_PREDICTORS = config$variant_predictors
BOOTSTRAP_N = config$bootstrap_iterations
MIN_PATIENT_CUTOFF = config$occurance_cutoff
VARIANTS_CUTOFF = config$occurance_cutoff

###
# Process categorical phenotypes
# Stats: AUPRC
###
# Load variants with quantitative and categorical phenotypes
filePath = sprintf("output/%s/%s_variants_phenotypes.csv", toupper(GENE), GENE)
if (file.exists(filePath)) varPhenotypes = fread(filePath, header = T)

# Load variant prediction (VP) scores
filePath = paste("input", toupper(GENE), UNIQUE_VARIANTs_PATH, sep = "/")
if (!file.exists(filePath)) stop("missing variants")
varPredictors = fread(filePath, select = c("variant_name",
                                           unlist(VARIANT_PREDICTORS, use.names = F)))

# Helper function: normalize to 0-1 range
# When fill is set to a number, NA values will be filled with the n*100-th quantile of the data
# Example: when fill is set to 0.5, NA values will be filled with the 50-th quantile of the data
# Cutoff sets the floor and ceiling. values outside of that range will be set to 0 and 1, respectively.
# Example: when cutoff is set to 0.05, values out of the 5-95% range will be set to 0 and 1, respectively. 
normRange = function(vec, fill = NA, cutoff = 0.05) {
  # If no value at all, set everything to fill
  if (all(is.na(vec))) return(rep(fill, length(vec)))
  
  # Apply floor and ceiling cutoff
  if (cutoff > 0) {
    # Compute floor and ceiling
    floor = quantile(vec, cutoff, na.rm = T)
    ceiling = quantile(vec, 1 - cutoff, na.rm = T)
    
    # Apply floor and ceiling
    vec[vec <= floor & !is.na(vec)] = floor
    vec[vec >= ceiling & !is.na(vec)] = ceiling
  }
  
  # Normalize
  norm = (vec - min(vec, na.rm = T)) / (max(vec, na.rm = T) - min(vec, na.rm = T))
  
  # Fill vector
  if (!is.na(fill)) norm[is.na(norm)] = quantile(norm, fill, na.rm = T)
  
  return(norm)
}

# Normalize variant score
# NA values will be filled with 0.5
# A 5% floor and ceiling will be applied
cols = unlist(VARIANT_PREDICTORS, use.names = F)
varPredictors[ , (cols) := lapply(.SD, normRange), .SDcols = cols]

# Remove predictors that didn't make predictions for at least the number of variants set by the VARIANTS_CUTOFF
colsKept = apply(varPredictors[, -c("variant_name"), with = F], 2, function(col) {
  length(na.omit(col)) >= VARIANTS_CUTOFF
})
varPredictors = varPredictors[, -names(colsKept[!colsKept]), with = F]
cols = names(colsKept[colsKept])

# Prepare parallel processing
no_cores = detectCores(logical = TRUE)
cl = makeCluster(no_cores - 1)  
registerDoParallel(cl)

# Benchmark for each categorical phenotype
catePhenotypes = bPhenotypes[field_type == "categorical"]
if (nrow(catePhenotypes) < 1) stop("No Categorical phenotypes")
results = lapply(1:nrow(catePhenotypes), function(index) {
  fieldId = catePhenotypes[index, field_id]

  # Extract variant name and phenotype assignment
  columns = c("variant_name", "eid", fieldId)
  catPhenotype = unique(varPhenotypes[, ..columns])
  setnames(catPhenotype, as.character(fieldId), "p")
  
  # Helper function: check if a patient has a categorical phenotype
  hasCatPhenotype = function(p) {
    # If NA exists, use NA
    if (any(is.na(p))) return(!is.na(p))
    
    return(!(p == ""))
  }

  # Check if the phenotype has passed the cutoff
  numPatient = sum(hasCatPhenotype(catPhenotype$p))
  if (numPatient <= MIN_PATIENT_CUTOFF)
    stop(sprintf("The number of patients with the phenotype (=%d) is less than or equal to the cutoff (=%d)",
                 numPatient, MIN_PATIENT_CUTOFF))
  
  # Compute per-patient phenotype score
  merged = merge(catPhenotype, varPredictors, by = "variant_name")
  merged = merged[, lapply(.SD[, cols, with = F], sum), by = c("eid", "p")]
  
  # Bootstrap resampling
  auprcs = parSapply(cl, 1:BOOTSTRAP_N, function(iteration, merged, n) {
    library(yogiroc)
    library(data.table)
    library(logr)
    log_print(sprintf("Bootstrapping iteration %d/%d", iteration, n))
    
    sampled = sample(1:nrow(merged), nrow(merged), replace = T)
    sampled = merged[sampled]
    
    # Helper function: check if a patient has a categorical phenotype
    hasCatPhenotype = function(p) {
      # If NA exists, use NA
      if (any(is.na(p))) return(!is.na(p))
      
      return(!(p == ""))
    }
    
    # Compute AUPRC
    prcObj = yr2(truth = hasCatPhenotype(sampled$p), scores = sampled[, -c(1:2)])
    auprcs = auprc(prcObj, balanced = TRUE)
    
    return(auprcs)
  }, merged, BOOTSTRAP_N)
  
  # Compute average
  auprcAvgs = rowMeans(auprcs)
  
  # Compute 95% CI for each predictor
  auprcCis = apply(auprcs, 1, function(vals) {
    return(paste(quantile(vals, 0.05), quantile(vals, 0.95), sep = ","))
  })
  
  # Compute P values for each predictor pair
  auprcPvals = expand.grid(pred1 = rownames(auprcs), pred2 = rownames(auprcs))
  auprcPvals = as.data.table(auprcPvals)
  auprcPvals$p_val = apply(auprcPvals, 1, function(row) {
    # Get predictors
    pred1 = row[["pred1"]]
    pred2 = row[["pred2"]]
    
    # Get AUPRC distributions
    pred1Dist = auprcs[pred1,]
    pred2Dist = auprcs[pred2,]
    
    # Compute difference distribution
    diffDist = pred1Dist - pred2Dist
    
    # Calculate the probability of P1 is not bigger than P2
    # (i.e. the difference is smaller than or equal to 0)
    pVal = sum(diffDist <= 0) / length(diffDist)
    
    return(pVal)
  })
  
  # Format auprcs
  ret = as.data.table(auprcs, keep.rownames = T)
  ret = ret[, .(auprcs = paste0(.SD, collapse = ",")), by = "rn"]
  ret$auprc_avg = auprcAvgs
  ret$auprc_ci = auprcCis
  results = list(variants = merged, auprcs = ret, auprcs_pval = auprcPvals)
  
  # Cache results
  outputPath = sprintf("output/%s/%s_%s_auprc.rds", toupper(GENE), GENE, fieldId)
  saveRDS(results, outputPath)
  
  return(results)
})

# Collect auprcs
catePhenotypes = catePhenotypes$field_id
auprcs = lapply(1:length(results), function(index) {
  res = results[[index]]
  vals = res$auprcs
  vals$rn = names(VARIANT_PREDICTORS)[1:length(vals$rn)]
  vals$phenotype = bPhenotypes[field_id == catePhenotypes[[index]], field_description]
  vals$code = catePhenotypes[[index]]
  return(vals[, .(predictor = rn, phenotype, code, auprc = auprc_avg, auprc_ci)])
})
auprcs = rbindlist(auprcs)
auprcs$type = "binary"
auprcs$index = 1:nrow(auprcs)

# Helper function: format CI
formatCIString = function(ranges) {
  ranges = str_split(ranges, ",", simplify = T)
  ranges = apply(ranges, 1, as.numeric)
  ranges = formatC(round(ranges, 2), format='f', digits=2)
  return(apply(ranges, 2, paste, collapse = ",<br>"))
}

# Format CI
plotTable = auprcs[, .(phenotype, predictor, type, index, avg_score = auprc,
                       avg_score_ci = lapply(auprc_ci, formatCIString))]

# Order predictors by its average performance
predictorPerf = plotTable[, .(avg_score = mean(abs(avg_score))), by = "predictor"]
predictorPerf[order(avg_score, decreasing = T), predictor_index := 1:nrow(predictorPerf)]
plotTable = merge(plotTable, predictorPerf[, .(predictor, predictor_index)], by = "predictor")

# Plot AUPRC heatmap
plot = plotTable %>%
  mutate(phenotype = sprintf("%s<br>*(%s)*", phenotype, type),
         phenotype = fct_reorder(phenotype, -index),
         name = fct_reorder(predictor, -predictor_index)) %>%
  ggplot(aes(x = name, y = phenotype, fill = avg_score)) +
  geom_tile() +
  geom_richtext(aes(label = sprintf("%.2f<br>[%s]", avg_score, avg_score_ci)),
                size=5, fill = NA, label.color = NA) +
  labs(x = "Variant Effect Predictors<br><span style='font-size:12pt'>(ordered fron left to right by the mean of absolute values)</span>",
       y = "Phenotype",
       fill = "Mean AUPRC") +
  scale_fill_gradientn(colors = c("#ffffff", "#67a9cf"), na.value = "#d8d8d8", n.breaks = 3) +
  ggtitle(paste(toupper(GENE), "with bootstrapping, N =", BOOTSTRAP_N),
          "5-95% range in bracket") +
  theme_minimal(base_size = 18) +
  theme(axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1, size = 20),
        axis.text.y = element_markdown(size = 20), legend.position = "bottom",
        axis.title.x = element_markdown(),
        legend.title.align = 1, legend.title = element_markdown(size = 16, vjust = 0.9),
        legend.key.width = unit(0.3, "in"))

ggsave(sprintf("output/%s/%s_cat_bootstrap.png", toupper(GENE), GENE), plot, dpi = 300,
       height = 4.5 + length(unique(plotTable$phenotype)),
       width = max(10, floor(length(VARIANT_PREDICTORS) * 1.1)), units = "in")
