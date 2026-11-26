#!/usr/bin/env bash
set -euo pipefail

# ==================== Build Script for BLDMAKE ===================== #
# Usage: bldit_bldmake.sh                                             #
# Requirements: I/O API & netCDF libraries; a Fortran compiler        #
#                                                                     #
# To report problems or request help with this script/program:        #
#             http://www.cmascenter.org                               #
# =================================================================== #

# Variables expected from the calling environment (fail early with a clear message)
: "${compiler:?compiler must be set}"
: "${compilerString:?compilerString must be set}"
: "${CMAQ_HOME:?CMAQ_HOME must be set}"
: "${CMAQ_REPO:?CMAQ_REPO must be set}"
: "${myFC:?myFC must be set}"
: "${myFFLAGS:=}"

#> Recompile BLDMAKE from source if requested or if it does not exist
# ${CompileBLDMAKE+x} is true when the variable is set (even if empty), like csh's $?var
if [[ -n ${CompileBLDMAKE+x} || ! -f ${BLDER:-} ]]; then

    #> Compiler-specific flags (PGI needs this to handle backslashes in quoted strings)
    add_flags=()
    if [[ ${compiler} == pgi ]]; then
        add_flags=(-Mbackslash)
    fi

    #> Split the user's Fortran flags into an array
    read -r -a fflags <<< "${myFFLAGS}"

    #> Set BLDER to default path
    BLDEXE="bldmake_${compilerString}.exe"
    BLDDIR="${CMAQ_HOME}/UTIL/bldmake"
    export BLDER="${BLDDIR}/${BLDEXE}"

    #> Make bldmake directory if it does not exist
    mkdir -pv "${BLDDIR}"

    #> BLDMAKE source files
    BLDSRCDIR="${CMAQ_REPO}/UTIL/bldmake/src"
    flist=(
        cfg_module
        bldmake
        parser
        utils
    )

    #> Clean destination BLDMAKE directory (-f: don't fail if nothing to remove)
    rm -f "${BLDDIR}"/*.o "${BLDDIR}"/*.mod "${BLDER}"

    #> Create object files
    pushd "${BLDSRCDIR}" > /dev/null
    for file in "${flist[@]}"; do
        "${myFC}" -c "${add_flags[@]}" "${fflags[@]}" "${file}.f" -o "${BLDDIR}/${file}.o"
    done
    popd > /dev/null

    #> Compile BLDMAKE
    pushd "${BLDDIR}" > /dev/null
    objs=(*.o)
    "${myFC}" "${objs[@]}" -o "${BLDEXE}"
    if [[ ! -e ${BLDEXE} ]]; then
        printf '\n ***ERROR*** BLDMAKE Compile failed\n\n' >&2
        exit 1
    fi
    chmod 755 "${BLDEXE}"
    printf '\n Finish building %s\n' "${BLDEXE}"
    popd > /dev/null

fi

exit 0
