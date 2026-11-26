#!/usr/bin/env bash
#
# ================ CCTMv6.X Mechanism Build Script ====================
# Usage: bldit_mech.sh <compiler> [<version>] &> bldit_mech.log
# Requirements: I/O API & netCDF libraries, a Fortran compiler,
#               and MPI for multiprocessor computing
#
# To report problems or request help with this script/program:
#             http://www.cmascenter.org
# =======================================================================
set -euo pipefail

usage() {
    echo "usage: $0 <compiler> [<version>]" >&2
    echo " where <compiler> is intel, pgi or gcc" >&2
}

#> Set Compiler Identity by User Input: Options -> intel | pgi | gcc
case $# in
    1) export compiler=$1 compilerVrsn=Empty ;;
    2) export compiler=$1 compilerVrsn=$2 ;;   # compiler name and version provided
    *) usage; exit 2 ;;
esac

#> Source the config file to set the build environment
#  (config_cmaq.sh is the Bash port of config_cmaq.csh)
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${script_dir}/../.."

set +u                      # the config file may reference unset variables
source ./config_cmaq.sh
set -u

: "${CMAQ_HOME:?CMAQ_HOME must be set by config_cmaq.sh}"

# =======================================================================
#> Begin User Input Section
# =======================================================================
# Each value below is only a default: anything already in the environment
# (e.g. exported by bldit_cctm.sh) wins.

#> Name of the mechanism, if not inherited
export Mechanism="${Mechanism:-cb6r5_ae7_aq}"
export MECH="${Mechanism}"

#> Solver approach, if not inherited (options: ros3, smvgear, ebi)
# Warning: If you are building a new mechanism or modifying an existing
# one, the ebi solver approach could very possibly encounter convergence
# or other issues that will lead to inaccuracies. The CMAQ development
# team recommends using one of the generalized solvers (ros3 or smvgear).
# If you would like to use ebi anyway, please benchmark your results for
# important constituents like O3, NO, NO2, OH etc with the generalized
# solvers and compare your results using ebi to these benchmarks.
export ChemSolver="${ChemSolver:-ebi}"

#> Location of input mechanism files
export MECH_SRC="${MECH_SRC:-${CMAQ_HOME}/CCTM/scripts/${Mechanism}}"

#> Location of input tracer files
export TRAC_NML="${TRAC_NML:-${CMAQ_HOME}/CCTM/scripts/${Mechanism}/Species_Table_TR_0.nml}"

#> Location of output mechanism files
export MECH_OUT="${MECH_OUT:-${CMAQ_HOME}/CCTM/scripts/${Mechanism}}"

#> Location of EBI solver output files (ignore if using Ros3 or Smvgear)
export EBI_SOLVER_OUT="${EBI_SOLVER_OUT:-${CMAQ_HOME}/CCTM/scripts/ebi_${Mechanism}}"

#> Overwrite existing mechanism files? If CLOBBER_MECH is FALSE and files
#> already exist, the script halts.
CLOBBER_MECH="${CLOBBER_MECH:-FALSE}"

# Halt if any of the given destination files exists and clobbering is off.
# $1 = first line of the message, remaining args = destination files
clobber_check() {
    local msg=$1 f
    shift
    [[ ${CLOBBER_MECH} == FALSE ]] || return 0
    for f in "$@"; do
        if [[ -e ${f} ]]; then
            {
                echo ""
                echo "${msg}"
                echo "If you would like to overwrite the existing files, uncomment clobber_mech"
                echo "if you are using the bldit_cctm script or set CLOBBER_MECH "
                echo "to TRUE if you are using bldit_mech stand-alone."
                echo ""
            } >&2
            exit 1
        fi
    done
}

###################### CHEMMECH Processor #############################
#> Build Mechanism Files and instruct build-make to look
#> in the CHEMMECH output folder for the files
if [[ ! -e ${MECH_SRC} ]]; then
    {
        echo "bldit_mech.sh: ${Mechanism} input folder cannot be found. "
        echo "    Please select a valid mechanism input location."
    } >&2
    exit 1
fi
if [[ ! -e ${TRAC_NML} ]]; then
    {
        echo "bldit_mech.sh: ${TRAC_NML} file cannot be found. "
        echo "    Please select a valid file."
    } >&2
    exit 1
fi
mkdir -p "${MECH_OUT}"      # create output folder if it does not already exist

cd "${CMAQ_HOME}/UTIL/chemmech/scripts"
if ! ./bldit_chemmech.csh "${compiler}"; then
    echo "CHEMMECH did not build correctly --> Build Process Halted" >&2
    exit 1
fi

# Copy files from MECH_SRC to the CHEMMECH input folder
export CHEMMECH_INPUT="${CMAQ_HOME}/UTIL/chemmech/input/${MECH}"
mkdir -p "${CHEMMECH_INPUT}"
cp -f "${MECH_SRC}"/* "${CHEMMECH_INPUT}/"
cp -f "${TRAC_NML}"   "${CHEMMECH_INPUT}/"

# Run CHEMMECH
cd "${CMAQ_HOME}/UTIL/chemmech/scripts"
if ! ./run_chemmech.csh "${compiler}" "${compilerVrsn}"; then
    echo "CHEMMECH did not run correctly --> Build Process Halted" >&2
    exit 1
fi

# Error out if the RXNS modules weren't created
CHEMMECH_OUTPUT="${CMAQ_HOME}/UTIL/chemmech/output/${MECH}"
if [[ ! -e ${CHEMMECH_OUTPUT}/RXNS_DATA_MODULE.F90 ||
      ! -e ${CHEMMECH_OUTPUT}/RXNS_FUNC_MODULE.F90 ]]; then
    echo "Mechanism module not created for ${Mechanism}" >&2
    exit 1
fi

# Error out if RXNS modules already exist in destination directory
clobber_check "Mechanism files already exist in the destination directory." \
    "${MECH_OUT}/RXNS_DATA_MODULE.F90" \
    "${MECH_OUT}/RXNS_FUNC_MODULE.F90"

#> Copy files back to mechanism location
cp -f "${CHEMMECH_OUTPUT}"/RXNS*MODULE.F90 "${MECH_OUT}/."
cp -f "${CHEMMECH_OUTPUT}"/[AEGN]*.nml "${MECH_OUT}/."
if [[ ${COMPUTE_DELTA_ATOMS:-} == T ]]; then
    cp -f "${CHEMMECH_OUTPUT}"/mech*.def "${MECH_OUT}/."
fi

#> Copy mechanism markdown file
MECH_MD_DIR="${MECH_OUT}/../mechanism_information/${Mechanism}"
if [[ -e ${MECH_MD_DIR} ]]; then
    cp -f "${CHEMMECH_OUTPUT}"/mech*.md "${MECH_MD_DIR}/"
fi

#################### CSQY Photolysis Processor ##########################

#> Copy inputs to inline photolysis preprocessor
CSQY_INPUT="${CMAQ_HOME}/UTIL/inline_phot_preproc/input/${MECH}"
mkdir -p "${CSQY_INPUT}"
cp -f "${MECH_OUT}/RXNS_DATA_MODULE.F90" "${CSQY_INPUT}/."

#> Build CSQY data table for inline photolysis
cd "${CMAQ_HOME}/UTIL/inline_phot_preproc/scripts"
if ! ./bldrun.inline_phot_preproc.csh "${compiler}"; then
    echo "Preparation of CSQY Table did not build or run correctly --> Build Process Halted" >&2
    exit 1
fi

# Error out if the CSQY data files weren't created
CSQY_OUTPUT="${CMAQ_HOME}/UTIL/inline_phot_preproc/output/${MECH}"
if [[ ! -e ${CSQY_OUTPUT}/CSQY_DATA_${MECH} ]]; then
    echo "CSQY_${MECH} not created" >&2
    exit 1
fi

# Error out if the CSQY data file already exists in destination directory
clobber_check "CSQY Data file already exists in the destination directory." \
    "${MECH_OUT}/CSQY_DATA_${MECH}"

#> Copy files back to mechanism location
cp -f "${CSQY_OUTPUT}/CSQY_DATA_${MECH}" "${MECH_OUT}/."

#################### EBI Solver Processor ##########################

#> if EBI (Euler Backward-Iterative) chemical solver is set, build
#> mechanism-dependent EBI files and instruct build-make to look in
#> the create-ebi output folder for the files.
if [[ ${ChemSolver} == ebi ]]; then

    #> Copy inputs to EBI input folder
    EBI_INPUT="${CMAQ_HOME}/UTIL/create_ebi/input/${MECH}"
    mkdir -p "${EBI_INPUT}"
    cp -f "${MECH_OUT}/RXNS_DATA_MODULE.F90" "${EBI_INPUT}/."

    # Build and run Create_EBI
    cd "${CMAQ_HOME}/UTIL/create_ebi/scripts"
    if ! ./bldrun_create_ebi.csh "${compiler}"; then
        echo "CREATE_EBI did not build or run correctly --> Build Process Halted" >&2
        exit 1
    fi

    # Error out if the EBI output files weren't created
    EBI_OUTPUT="${CMAQ_HOME}/UTIL/create_ebi/output/ebi_${MECH}"
    if [[ ! -e ${EBI_OUTPUT}/hrrates.F ]]; then
        echo "EBI solver not created for ${Mechanism}" >&2
        exit 1
    fi

    mkdir -p "${EBI_SOLVER_OUT}"   # create EBI solver output folder

    # Error out if EBI files already exist in destination directory
    clobber_check "EBI solver files already exist in the destination directory." \
        "${EBI_SOLVER_OUT}/hrrates.F"

    # Copy EBI files to EBI_SOLVER_OUT directory
    cp -f "${EBI_OUTPUT}"/hr*.F "${EBI_SOLVER_OUT}/."
fi

exit 0
