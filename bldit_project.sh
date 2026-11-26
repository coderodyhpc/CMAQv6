#!/usr/bin/env bash

# ================= CMAQv6.X Extraction Script ==================== #
# Usage: ./extract_scripts.sh [epa]   (run from the repository top-level)
# Requirements: CMAQ git source code repository                       #
#                                                                     #
# To report problems or request help with this script/program:        #
#             http://www.cmascenter.org/help_desk.cfm                 #
# =================================================================== #

#> This script may be executed when first downloading or cloning the CMAQ
#> repository. The routine will copy important scripts including config_cmaq,
#> bldit_cctm, and run_cctm as well as scripts for other utilities into
#> a $CMAQ_HOME project directory of the user's choice.
#>
#> Default location for CMAQ model build is one directory above
#> the repository. The user may also set their own preferred
#> directory.
set -euo pipefail

CMAQ_HOME=/home/username/path

#> This section allows users to choose explicitly which tools
#> to make available from the repo. For each selected tool,
#> extract_scripts will copy any build and run scripts
#> out of the repo for you. Set each to [Y/N]
EXT_CCTM=Y

# Utilities
EXT_JPROC=Y
EXT_MECH_BUILD=Y

# Pre-Processing Tools
EXT_BCON=Y
EXT_ICON=Y
EXT_MCIP=Y
EXT_CREATE_OMI=Y

# Post-Processing Tools
EXT_COMBINE=Y
EXT_CALC_TMETRIC=Y
EXT_HR2DAY=Y
EXT_SITECMP=Y
EXT_SITECMP_DAILYO3=Y
EXT_WRITESITE=Y

#> model source code repository location (the directory the script is run from)
REPO_HOME="${PWD}"

#> Check that the host system is Linux-based
BLD_OS=$(uname -s)
if [[ ${BLD_OS} != Linux ]]; then
    echo "   ${BLD_OS} -> wrong bldit script for host!" >&2
    exit 1
fi

#> Check to make sure $CMAQ_HOME exists
if [[ ! -e ${CMAQ_HOME} ]]; then
    mkdir -pv "${CMAQ_HOME}"
elif [[ ! -d ${CMAQ_HOME} ]]; then
    echo "   *** target exists, but not a directory ***" >&2
    exit 1
fi

#> Return to repository top-level directory
cd "${REPO_HOME}"
if [[ ! -f config_cmaq.csh ]]; then
    echo "   *** config_cmaq.csh not found: run this script from the repository top-level ***" >&2
    exit 1
fi

#> Check for EPA Specification. If the user entered "epa" in the
#> command line, then commands for sourcing files on the EPA high
#> performance computing system will be invoked, otherwise they will
#> be ignored.
IS_EPA=0
if [[ $# -eq 1 && ( $1 == EPA || $1 == epa ) ]]; then
    IS_EPA=1
fi

# extract <reldir> <file-or-glob>...
#   Copies the named files (paths relative to <reldir> in the repository;
#   globs allowed) into the same <reldir> under $CMAQ_HOME, creating it first.
extract() {
    local dir=$1 pat
    shift
    mkdir -pv "${CMAQ_HOME}/${dir}"
    for pat in "$@"; do
        # shellcheck disable=SC2086  # unquoted on purpose: ${pat} may be a glob
        cp "${dir}"/${pat} "${CMAQ_HOME}/${dir}/"
    done
}

#===============================================================================
#> Copy config_cmaq.csh to Project directory and insert correct location
#> of the repository these scripts are coming from.
#===============================================================================
cp config_cmaq.csh "${CMAQ_HOME}/config_cmaq.csh"
sed -i '/setenv CMAQ_REPO \$CMAQ_HOME/c\ setenv CMAQ_REPO '"${REPO_HOME}" "${CMAQ_HOME}/config_cmaq.csh"
if (( IS_EPA )); then
    sed -i 's|# source /work/MOD3DEV/cmaq_common/cmaq_env.csh|source /work/MOD3DEV/cmaq_common/cmaq_env.csh|' \
        "${CMAQ_HOME}/config_cmaq.csh"
fi

#===============================================================================
#> Copy CCTM scripts
#===============================================================================
if [[ ${EXT_CCTM} == Y ]]; then
    extract CCTM/scripts \
        bldit_cctm.csh bldit_mech.csh lonlat.csv \
        isam_control.2018_12NE3.txt isam_control.2016_12SE1.txt isam_control.2022_12SE1.txt \
        sensinput.2018_12NE3.dat sensinput.2016_12SE1.dat sensinput.2022_12SE1.dat \
        'run_cctm_*.csh'
fi

#===============================================================================
#> Copy JPROC scripts
#===============================================================================
if [[ ${EXT_JPROC} == Y ]]; then
    extract UTIL/jproc/scripts bldit_jproc.csh run_jproc.csh
fi

#===============================================================================
#> Copy CHEMMECH, INLINE_PHOT_PREPROC and CREATE_EBI scripts
#===============================================================================
if [[ ${EXT_MECH_BUILD} == Y ]]; then
    extract UTIL/chemmech/scripts bldit_chemmech.csh run_chemmech.csh
    mkdir -pv "${CMAQ_HOME}"/UTIL/chemmech/{input,output}

    extract UTIL/inline_phot_preproc/scripts bldrun.inline_phot_preproc.csh
    mkdir -pv "${CMAQ_HOME}"/UTIL/inline_phot_preproc/{input,output}

    extract UTIL/create_ebi/scripts bldrun_create_ebi.csh
    mkdir -pv "${CMAQ_HOME}"/UTIL/create_ebi/{input,output}
fi

#===============================================================================
#> Copy BCON scripts
#===============================================================================
if [[ ${EXT_BCON} == Y ]]; then
    extract PREP/bcon/scripts bldit_bcon.csh run_bcon.csh
fi

#===============================================================================
#> Copy ICON scripts
#===============================================================================
if [[ ${EXT_ICON} == Y ]]; then
    extract PREP/icon/scripts bldit_icon.csh run_icon.csh
fi

#===============================================================================
#> Copy MCIP scripts & src
#===============================================================================
if [[ ${EXT_MCIP} == Y ]]; then
    extract PREP/mcip/scripts run_mcip.csh
    extract PREP/mcip/src '*'
fi

#===============================================================================
#> Copy create_omi scripts
#===============================================================================
if [[ ${EXT_CREATE_OMI} == Y ]]; then
    extract PREP/create_omi/scripts bldit_create_omi.csh get_toms_data.q run_create_omi.csh
fi

#===============================================================================
#> Copy Combine Post-Processor scripts
#===============================================================================
if [[ ${EXT_COMBINE} == Y ]]; then
    extract POST/combine/scripts bldit_combine.csh run_combine.csh
    mkdir -pv "${CMAQ_HOME}/POST/combine/scripts/spec_def_files"
    cp -L POST/combine/scripts/spec_def_files/SpecDef* "${CMAQ_HOME}/POST/combine/scripts/spec_def_files"
fi

#===============================================================================
#> Copy calc_tmetric Post-Processor scripts
#===============================================================================
if [[ ${EXT_CALC_TMETRIC} == Y ]]; then
    extract POST/calc_tmetric/scripts bldit_calc_tmetric.csh run_calc_tmetric.csh
fi

#===============================================================================
#> Copy hr2day Post-Processor scripts
#===============================================================================
if [[ ${EXT_HR2DAY} == Y ]]; then
    extract POST/hr2day/scripts bldit_hr2day.csh run_hr2day.csh
fi

#===============================================================================
#> Copy sitecmp Post-Processor scripts
#===============================================================================
if [[ ${EXT_SITECMP} == Y ]]; then
    extract POST/sitecmp/scripts \
        bldit_sitecmp.csh \
        run_sitecmp_AQS_Daily.csh run_sitecmp_AQS_Hourly.csh \
        run_sitecmp_CASTNET_Hourly.csh run_sitecmp_CSN.csh \
        run_sitecmp_IMPROVE.csh run_sitecmp_NADP.csh \
        run_sitecmp_SEARCH_Hourly.csh
fi

#===============================================================================
#> Copy sitecmp_dailyo3 Post-Processor scripts
#===============================================================================
if [[ ${EXT_SITECMP_DAILYO3} == Y ]]; then
    extract POST/sitecmp_dailyo3/scripts \
        bldit_sitecmp_dailyo3.csh run_sitecmp_dailyo3_AQS.csh run_sitecmp_dailyo3_CASTNET.csh
fi

#===============================================================================
#> Copy writesite Post-Processor scripts
#===============================================================================
if [[ ${EXT_WRITESITE} == Y ]]; then
    extract POST/writesite/scripts bldit_writesite.csh run_writesite.csh
fi

#===============================================================================
# Insert Job Scheduler Preface into Run Scripts for those working inside EPA.
# epa_scheduler.csh is a csh script, so run it with csh (it cannot be sourced
# from Bash); the settings it may rely on are passed through the environment.
if (( IS_EPA )); then
    export CMAQ_HOME REPO_HOME IS_EPA \
           EXT_CCTM EXT_JPROC EXT_MECH_BUILD EXT_BCON EXT_ICON EXT_MCIP EXT_CREATE_OMI \
           EXT_COMBINE EXT_CALC_TMETRIC EXT_HR2DAY EXT_SITECMP EXT_SITECMP_DAILYO3 EXT_WRITESITE
    csh -f /work/MOD3DEV/cmaq_common/epa_scheduler.csh   #>>> Comment Out if not at EPA
fi

#===============================================================================
#> Exit the Script
#===============================================================================
echo "Configuration and Run Scripts have been Extracted and placed in: ${CMAQ_HOME}"
echo "You may now edit these scripts to conform to your system and run options."

exit 0
