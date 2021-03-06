#!/bin/bash
#======================================================================================================
# Name:         rasterize.sh
# Description:  Reads a DSM point cloud file and outputs height and diffusion map image files.
# Dependencies: LAStools, PDAL, GDAL, python-gdal, ImageMagick, and jq.
#======================================================================================================


################################
# CONSTANT AND DEFAULT VALUES #
################################

# Flag to indicate if tmp files should be deleted at the end of the script.
DELETE_TMP_FILES=true

# Target sizes for height map and diffusion map image file outputs.
DEFAULT_SIZE_HEIGHT_MAP=512
DEFAULT_SIZE_DIFFUSION_MAP=4096

# Define tmp and output directories.
DIR_TMP=tmp
DIR_OUTPUT=output

# How much above the ground level, i.e. along the Z axis,
# do we want the heightmap origin coordinates to be set to.
Z_SHIFT=1

# Default PDAL pipeline configurations
PDAL_DEFAULT_RESOLUTION=0.05
PDAL_DEFAULT_OUTPUT_TYPE="mean"

# Template PDAL pipeline files.
PDAL_PIPELINE_DTM=templates/pipelines/dtm.json.template
PDAL_PIPELINE_RGB=templates/pipelines/rgb.json.template

# Expected dgalinfo string output pattern for size info.
REGEX_SIZE=".*Size is ([0-9]+), ([0-9]+).*"


#########################
# READ INPUT PARAMETERS #
#########################
while getopts ":h:d:r:t:i:" opt; do
  case $opt in
    h) size_height_map="$OPTARG"
    ;;
    d) size_diffusion_map="$OPTARG"
    ;;
    r) pdal_resolution="$OPTARG"
    ;;
    t) pdal_output_type="$OPTARG"
    ;;
    i) xyz_filename="$OPTARG"
    ;;
    \?) printf "\nInvalid option -$OPTARG\n\n" >&2
    exit 1
    ;;
  esac
done

# Verbosity.
verbose=true

# Check if input pointcloud filename was given.
if [ -z "$xyz_filename" ]
then
    printf "\nUse the -i option to input the path to the .xyz file to process.\n\n"
    exit 1
fi

# Set default height map size if not given as parameter.
if [ -z "$size_height_map" ]
then
    size_height_map=$DEFAULT_SIZE_HEIGHT_MAP
fi

# Set default diffusion map size if not given as parameter.
if [ -z "$size_diffusion_map" ]
then
    size_diffusion_map=$DEFAULT_SIZE_DIFFUSION_MAP
fi

# Set default pdal image processing resolution.
if [ -z "$pdal_resolution" ]
then
    pdal_resolution=$PDAL_DEFAULT_RESOLUTION
fi

# Set default pdal output type.
if [ -z "$pdal_output_type" ]
then
    pdal_output_type=$PDAL_DEFAULT_OUTPUT_TYPE
fi

# Verbosity
if [ $verbose = true ] ; then
    echo ""
    echo "Rasterizing with the following parameters: "
    echo "  Heightmap size: $size_height_map"
    echo "  Diffusion map size: $size_diffusion_map"
    echo "  PDAL resolution: $pdal_resolution"
    echo "  PDAL output type: $pdal_output_type"
    echo "  Input filename: $xyz_filename"
fi


###########################################
# CREATE TEMPORARY AND OUTPUT DIRECTORIES #
###########################################

# Create parent tmp directory if it doesn't exist already.
if [ ! -d $DIR_TMP ]; then mkdir $DIR_TMP; fi

# Create parent output directory if it doesn't exist already.
if [ ! -d $DIR_OUTPUT ]; then mkdir $DIR_OUTPUT; fi

# Get name of xyz file without its extension.
# Use this name as the directory name where created files will be outputted to.
filename=$(basename -- "$xyz_filename")
filename="${filename%.*}"

# Define target directories where created files will be saved.
target_tmp_dir="$DIR_TMP/$filename"
target_output_dir="$DIR_OUTPUT/$filename"

# Delete temporary files that the script creates.
# They may be left over from abruptly stopping the script during a previous run.
if [ -d $target_tmp_dir ]; then rm -Rf $target_tmp_dir; fi

# Create the tmp subdirectory where temporary files will be saved.
mkdir $target_tmp_dir

# Create output directory for the inputted file.
if [ ! -d $target_output_dir ]; then mkdir $target_output_dir; fi


###########################
# DEFINE OUTPUT FILENAMES #
###########################

# Final outout files.
heightmap_filename=$target_output_dir/heightmap.png
diffusionmap_filename=$target_output_dir/diffusion.png


###################
# CREATE DTM FILE #
###################

# Use LAStools to parse the xyzRGB pointcloud ASCII format data into a laz format file.
printf "\nParsing xyzRGB pointcloud file to LAZ...\n"

# Laz filename needs to match filename in pipeline json templates.
txt2las -parse xyzRGB -i $xyz_filename -o $target_tmp_dir/pointcloud.laz

# Create the GTiff DTM file...
printf "Creating GTiff DTM...\n"

# PDAL pipeline definition filename.
dtm_pipeline_filename=$target_tmp_dir/dtm.json

# Create the DTM pipeline JSON file.
sed "s/{RESOLUTION}/$pdal_resolution/g" $PDAL_PIPELINE_DTM | sed "s/{OUTPUT_TYPE}/$pdal_output_type/g" | sed "s/{OUTPUT_TYPE}/$pdal_output_type/g" | sed "s/{TMP_DIR}/${target_tmp_dir/\//\\\/}/g" > $dtm_pipeline_filename

# Use PDAL to create the GTiff DTM file.
pdal pipeline $dtm_pipeline_filename

# Use GDAL to fetch the size of the DTM.
gdalinfo_stdout="$(gdalinfo "$target_tmp_dir/dtm.tif" 2>&1)"


##################
# FETCH DTM SIZE #
##################

# Use GDAL to fetch the width and height of the DTM.
if [[ $gdalinfo_stdout =~ $REGEX_SIZE ]]
then
    width="${BASH_REMATCH[1]}"
    height="${BASH_REMATCH[2]}"
fi


###############################
# DEFINE SIZE OF OUTPUT FILES #
###############################

# Define the size of the heightmap and diffusion map outputs.
# Either width or height needs to be set to size_height_map/size_diffusion_map.
# Pick the one that is the longest from the DTM size that was fetched earlier.
if [ "$width" -gt "$height" ]; then
    heightmap_outsize="$size_height_map 0"
    diffusionmap_outsize="$size_diffusion_map 0"
else
    heightmap_outsize="0 $size_height_map"
    diffusionmap_outsize="0 $size_diffusion_map"
fi


#######################
# CREATING HEIGHT MAP #
#######################

# Verbosity.
printf "Creating grayscale heightmap...\n"

echo "gdal_translate -of PNG -ot Byte -scale -b 1 -outsize $heightmap_outsize "$target_tmp_dir/dtm.tif" $heightmap_filename"

# Use GDAL to create grayscale heightmap file.
gdal_translate -of PNG -ot Byte -scale -b 1 -outsize $heightmap_outsize "$target_tmp_dir/dtm.tif" $heightmap_filename

# Use ImageMagick to rescale canvas size to size_height_map x size_height_map pixels.
printf "Rescaling heightmap canvas to ${size_height_map}, ${size_height_map}...\n"
convert $heightmap_filename -resize "${size_height_map}x${size_height_map}" -background Black -gravity center -extent "${size_height_map}x${size_height_map}" $heightmap_filename


##########################
# CREATING DIFFUSION MAP #
##########################

# Verbosity.
printf "Creating RGB diffusionmap...\n"

# PDAL pipeline definition filename.
rgb_pipeline_filename=$target_tmp_dir/rgb.json

# Create the DTM pipeline JSON file.
sed "s/{RESOLUTION}/$pdal_resolution/g" $PDAL_PIPELINE_RGB | sed "s/{OUTPUT_TYPE}/$pdal_output_type/g" | sed "s/{TMP_DIR}/${target_tmp_dir/\//\\\/}/g" > $rgb_pipeline_filename

# Use PDAL to create the RGB GTiff DTM file.
pdal pipeline $rgb_pipeline_filename

# Use python-gdal to merge red, green, and blue tif files into a single rbg.tif file.
# This could probably have been done in the PDAL rgb pipeline filters.merge but it throws a malloc error for high resolutions.
# The name of the tif files that are being merged are set in the the rgb.json.template file.
gdal_merge.py -separate $target_tmp_dir/red.tif $target_tmp_dir/green.tif $target_tmp_dir/blue.tif -o $target_tmp_dir/rgb.tif

# Use GDAL to create the RGB diffusion map.
gdal_translate -of PNG -ot Byte -scale -b 1 -b 2 -b 3 -outsize $diffusionmap_outsize $target_tmp_dir/rgb.tif $diffusionmap_filename

# Use ImageMagick to rescale canvas size to size_diffusion_map x size_diffusion_map pixels.
printf "Rescaling diffusion map canvas to ${size_diffusion_map}, ${size_diffusion_map}...\n"
convert $diffusionmap_filename -resize "${size_diffusion_map}x${size_diffusion_map}" -background Black -gravity center -extent "${size_diffusion_map}x${size_diffusion_map}" $diffusionmap_filename

##########################################################
# FETCH AND SAVE BOUNDING BOX AND CENTER COORDINATE DATA #
##########################################################

# Use PDAL to get bounding box json.
bbox_json=$(pdal info -i "$target_tmp_dir/pointcloud.laz" | jq -r '.stats.bbox.native.bbox')

# Width.
maxx=$(echo $bbox_json | jq .maxx)
minx=$(echo $bbox_json | jq .minx)
dim_width=$(bc <<< "scale=2; $maxx - $minx")

# Height.
maxy=$(echo $bbox_json | jq .maxy)
miny=$(echo $bbox_json | jq .miny)
dim_height=$(bc <<< "scale=2; $maxy - $miny")

# Depth.
maxz=$(echo $bbox_json | jq .maxz)
minz=$(echo $bbox_json | jq .minz)
dim_depth=$(bc <<< "scale=2; $maxz - $minz")

# Center coordinates.
coord_center_x=$(bc <<< "scale=2; $minx + $dim_width/2")
coord_center_y=$(bc <<< "scale=2; $miny + $dim_height/2")
coord_center_z=$(bc <<< "scale=2; $minz + $dim_depth/2")

# Determine z position above ground level.
# Fetch it by quering for nearest point near the center coordinate...
z_center_ground_level=$(pdal info -i "$target_tmp_dir/pointcloud.laz" --query "$coord_center_x, $coord_center_y, $coord_center_z/1" | jq '.["unnamed"]["0"]["Z"]')

# ...and apply Z axis shift that was set at the begining of this script.
position_z=$(bc <<< "scale=10; -($z_center_ground_level - $minz + $Z_SHIFT)")

# Include new values into the bounding box json and update the json file.
echo $bbox_json | jq --arg w $dim_width '. + {width: $w | tonumber}' | \
    jq --arg h $dim_height '. + {height: $h | tonumber}' | \
    jq --arg d $dim_depth '. + {depth: $d | tonumber}' | \
    jq --arg z $position_z '. + {posz: $z | tonumber}' | \
    jq --arg cx $coord_center_x '. + {centerx: $cx | tonumber}'| \
    jq --arg cy $coord_center_y '. + {centery: $cy | tonumber}'| \
    jq --arg cz $coord_center_z '. + {centerz: $cz | tonumber}' > "$target_output_dir/bbox.json"

###########
# CLEANUP #
###########
# Delete all the temporary files created by the script.
if [ $DELETE_TMP_FILES = true ] ; then
    if [ -d $target_tmp_dir ]; then rm -Rf $target_tmp_dir; fi

    # Remove auxiliary files.
    rm $target_output_dir/*.aux.xml
fi

echo "All done."
