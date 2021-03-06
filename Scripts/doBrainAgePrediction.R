library( ANTsR )
library( ANTsRNet )
library( keras )

args <- commandArgs( trailingOnly = TRUE )

if( length( args ) == 0 )
  {
  helpMessage <- paste0( "Usage:  Rscript doBrainAgePrediction.R outputCsvFile inputT1_1 inputT1_2 inputT1_3 ...\n" )
  stop( helpMessage )
  } else {
  outputCsvFile <- args[1]
  inputFileNames <- args[2:length( args )]
  }

#################
#
#  Preprocessing function
#      * Denoising
#      * N4 bias correction
#      * histogram or regression intensity matching
#

antsPreprocessImage <- function( image, mask = NULL, doBiasCorrection = TRUE,
  doDenoising = TRUE, referenceImage = NULL, matchingType = c( "regression", "histogram" ),
  verbose = TRUE )
  {
  preprocessedImage <- image

  # Do bias correction
  if( doBiasCorrection == TRUE )
    {
    if( verbose == TRUE )
      {
      cat( "Preprocessing:  bias correction.\n" )
      }
    if( is.null( mask ) )
      {
      preprocessedImage <- n4BiasFieldCorrection( image, shrinkFactor = 4, verbose = verbose )
      } else {
      preprocessedImage <- n4BiasFieldCorrection( image, mask, shrinkFactor = 4, verbose = verbose )
      }
    }

  # Do denoising
  if( doDenoising == TRUE )
    {
    if( verbose == TRUE )
      {
      cat( "Preprocessing:  denoising.\n" )
      }
    if( is.null( mask ) )
      {
      preprocessedImage <- denoiseImage( preprocessedImage, shrinkFactor = 1, verbose = verbose )
      } else {
      preprocessedImage <- denoiseImage( preprocessedImage, mask, shrinkFactor = 1, verbose = verbose )
      }
    }

  # Do image matching
  if( ! is.null( referenceImage ) )
    {
    if( verbose == TRUE )
      {
      cat( "Preprocessing:  intensity matching.\n" )
      }
    if( matchingType == "regression" )
      {
      preprocessedImage <- regressionMatchImage( preprocessedImage, referenceImage )
      } else if( matchingType == "histogram" ) {
      preprocessedImage <- histogramMatchImage( preprocessedImage, referenceImage )
      } else {
      stop( paste0( "Error:  unrecognized match type = ", matchingType, "\n" ) )
      }
    }
  return( preprocessedImage )
  }

#################
#
#  Data augmentation
#

brainAgeDataAugmentation <- function( image, imageSubsampled,
  patchSize = 96L, batchSize = 1L, affineStd = 0.01, verbose = TRUE )
  {
  # Channel 1: original image/patch
  # Channel 2: difference image/patch with MNI average
  numberOfChannels <- 2

  imageOffset <- 10
  imageDimensions <- dim( image )
  imageSubsampledDimensions <- dim( imageSubsampled )

  mniImageFileName <- paste0( getwd(), "/mniAverage.nii.gz" )
  if( ! file.exists( mniImageFileName ) )
    {
    if( verbose == TRUE )
      {
      cat( "Data augmentation:  downloading MNI average image.\n" )
      }
    mniUrl <- "https://github.com/ANTsXNet/BrainAgeGender/blob/master/Data/Templates/mniAverage.nii.gz?raw=true"
    download.file( mniUrl, mniImageFileName, quiet = !verbose )
    }
  mniAverage <- antsImageRead( mniImageFileName ) %>% antsCopyImageInfo2( image )

  mniImageSubsampledFileName <- paste0( getwd(), "/mniAverageSubsampled.nii.gz" )
  if( ! file.exists( mniImageSubsampledFileName ) )
    {
    if( verbose == TRUE )
      {
      cat( "Data augmentation:  downloading MNI average image.\n" )
      }
    mniUrl <- "https://github.com/ANTsXNet/BrainAgeGender/blob/master/Data/Templates/mniAverageSubsampled.nii.gz?raw=true"
    download.file( mniUrl, mniImageSubsampledFileName, quiet = !verbose )
    }
  mniAverageSubsampled <- antsImageRead( mniImageSubsampledFileName ) %>%
    antsCopyImageInfo2( imageSubsampled )

  imageDifference <- image - mniAverage
  imageSubsampledDifference <- imageSubsampled - mniAverageSubsampled

  imageArray <- array( data = NA, dim = c( batchSize, imageSubsampledDimensions, numberOfChannels ) )
  patchArray <- array( data = NA, dim = c( batchSize, rep( patchSize, 3 ), numberOfChannels ) )

  randomImages <- randomImageTransformAugmentation( imageSubsampled,
    interpolator = c( "linear","linear" ), list( list( imageSubsampled, imageSubsampledDifference ) ),
    list( imageSubsampledDifference ), sdAffine = affineStd, n = batchSize )

  for( i in seq_len( batchSize ) )
    {
    lowerIndices <- rep( NA, 3 )
    for( d in seq_len( 3 ) )
      {
      lowerIndices[d] <- sample( imageOffset:( imageDimensions[d] - patchSize - imageOffset ), 1 )
      }
    upperIndices <- lowerIndices + rep( patchSize, 3 ) - 1
    patch <- cropIndices( image, lowerIndices, upperIndices )
    patchDifference <- cropIndices( imageDifference, lowerIndices, upperIndices )

    imageArray[i,,,,1] <- as.array( randomImages$outputPredictorList[[i]][[1]] %>% iMath( "Normalize" ) )
    imageArray[i,,,,2] <- as.array( randomImages$outputPredictorList[[i]][[2]] )
    patchArray[i,,,,1] <- as.array( patch )
    patchArray[i,,,,2] <- as.array( patchDifference )
    }
  return( list( imageArray, patchArray ) )
  }

#################
#
#  Main routine
#

verbose <- TRUE

targetTemplateDimension <- c( 192L, 224L, 192L )

channelSize <- 2L
patchSize <- c( rep( 96L, 3L ), channelSize )
numberOfSamplesPerSubject <- 10L
affineStd <- 0.1

# Prepare the template

templateFileName <- paste0( getwd(), "/template_brainAge.nii.gz" )
if( ! file.exists( templateFileName ) )
  {
  if( verbose == TRUE )
    {
    cat( "Brain age:  downloading template.\n" )
    }
  templateUrl <- "https://github.com/ANTsXNet/BrainAgeGender/blob/master/Data/Templates/template_brainAge.nii.gz?raw=true"
  download.file( templateUrl, templateFileName, quiet = !verbose )
  }
originalTemplate <- antsImageRead( templateFileName )
template <- resampleImage( originalTemplate, targetTemplateDimension,
  useVoxels = TRUE, interpType = "linear" )
templateProbabilityMask <- brainExtraction( template, verbose = verbose )
templateBrainNormalized <- ( template * templateProbabilityMask ) %>% iMath( "Normalize" )
templateSubsampled <- resampleImage( template,
  as.integer( floor( targetTemplateDimension / 2 ) ), useVoxels = TRUE,
  interpType = "linear" )

# Prepare the model and load the weights

classes <- c( "Site", "Age", "Gender" )
numberOfClasses <- as.integer( channelSize * length( classes ) )
siteNames <- c( "DLBS", "HCP", "IXI", "NKIRockland", "OAS1_", "SALD" )

inputImageSize = c( dim( templateSubsampled ), channelSize )
resnetModel <- createResNetModel3D( inputImageSize,
  numberOfClassificationLabels = 1000, layers = 1:4,
  residualBlockSchedule = c(3, 4, 6, 3),
  lowestResolution = 64, cardinality = 64,
  mode = "classification")
penultimateLayerName <- as.character(
  resnetModel$layers[[length( resnetModel$layers ) - 1]]$name )
siteLayer <- layer_dense( get_layer( resnetModel, penultimateLayerName )$output,
  units = numberOfClasses, activation = "sigmoid" )
ageLayer <- layer_dense( get_layer( resnetModel, penultimateLayerName )$output,
  units = 1L, activation = "linear" )
genderLayer <- layer_dense( get_layer( resnetModel, penultimateLayerName )$output,
  units = 1L, activation = "sigmoid" )

inputPatch <- layer_input( patchSize )
model <- keras_model( inputs = list( resnetModel$input, inputPatch ),
  outputs = list( siteLayer, ageLayer, genderLayer ) )

weightsFileName <- paste0( getwd(), "/resNet4LayerLR64Card64b.h5" )
if( ! file.exists( weightsFileName ) )
  {
  if( verbose == TRUE )
    {
    cat( "Brain age:  downloading model weights file.\n" )
    }
  weightsFileName <- getPretrainedNetwork( "brainAgeGender", weightsFileName )
  }
load_model_weights_hdf5( model, weightsFileName )

brainAgesMean <- rep( NA, length( inputFileNames ) )
brainAgesStd <- rep( NA, length( inputFileNames ) )
brainGendersMean <- rep( NA, length( inputFileNames ) )
brainGendersStd <- rep( NA, length( inputFileNames ) )
for( i in seq_len( length( inputFileNames ) ) )
  {
  inputImage <- antsImageRead( inputFileNames[i] )
  if( verbose )
    {
    cat( "Preprocessing input image ", inputFileNames[i], ".\n", sep = '' )
    }
  inputImage <- antsPreprocessImage( inputImage, doDenoising = FALSE )
  if( verbose )
    {
    cat( "Brain extraction.\n" )
    }
  inputProbabilityBrainMask <- brainExtraction( inputImage, verbose = TRUE )
  inputBrain <- inputProbabilityBrainMask * inputImage
  inputBrainNormalized <- inputBrain %>% iMath( "Normalize" )

  if( verbose )
    {
    cat( "Registration to template.\n" )
    }
  templatexInputRegistration <- antsRegistration( fixed = templateBrainNormalized,
    moving = inputBrainNormalized, typeofTransform = "Affine", verbose = verbose )

  inputImageWarped <- antsApplyTransforms( template, inputImage,
    templatexInputRegistration$fwdtransforms, interpolator = "linear" )
  inputImageWarped <- inputImageWarped %>% iMath( "Normalize" )
  inputImageWarpedSubsampled <- antsApplyTransforms( templateSubsampled, inputImage,
    templatexInputRegistration$fwdtransforms, interpolator = "linear"  )
  inputImageWarpedSubsampled <- inputImageWarpedSubsampled %>% iMath( "Normalize" )

  augmentation <- brainAgeDataAugmentation( inputImageWarped, inputImageWarpedSubsampled,
    batchSize = numberOfSamplesPerSubject, affineStd = affineStd, verbose = verbose )
  predictions <- predict( model, augmentation, verbose = verbose )

  # siteDataFrame <- data.frame( matrix( predictions[[1]], ncol = length( siteNames ) ) )
  # colnames( siteDataFrame ) <- siteNames
  # for( k in seq_len( nrow( siteDataFrame ) ) )
  #   {
  #   siteDataFrame[k,] <- siteDataFrame[k,] / sum( siteDataFrame[k,] )
  #   }

  brainAgesMean[i] <- mean( as.numeric( predictions[[2]] ), na.rm = TRUE )
  brainAgesStd[i] <- sd( as.numeric( predictions[[2]] ), na.rm = TRUE )
  brainGendersMean[i] <- mean( as.numeric( predictions[[3]] ), na.rm = TRUE )
  brainGendersStd[i] <- sd( as.numeric( predictions[[3]] ), na.rm = TRUE )
  }

brainAgeDataFrame <- data.frame( FileName = inputFileNames, Age = brainAgesMean,
  Gender = brainGendersMean )

if( outputCsvFile != "None" && outputCsvFile != "none" )
  {
  write.csv( brainAgeDataFrame, file = outputCsvFile, row.names = FALSE )
  } else {
  print( brainAgeDataFrame )
  }




