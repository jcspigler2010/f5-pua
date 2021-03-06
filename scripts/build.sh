#!/bin/bash
#
# build offline version of build_pua.sh
scriptname=$(basename $0)
workingdir=$(mktemp -d -t pua.XXXXXXXXXX)
cleanup () {
  # runs on EXIT or CTRL-C
  echo
  echo "Cleaning up..."
  rm -rf "$workingdir"
}
trap cleanup EXIT

# This is a round about way to get the directory that the script was executed from...
pushd . > /dev/null
script_path="${BASH_SOURCE[0]}";
while([ -h "${script_path}" ]); do
    cd "`dirname "${script_path}"`"
    script_path="$(readlink "`basename "${script_path}"`")";
done
cd "`dirname "${script_path}"`" > /dev/null
script_path="`pwd`";
popd  > /dev/null

cd bin/
cp build_pua_template.sh build_pua.sh
chmod 755 build_pua.sh
echo __PUA_ARCHIVE__ >> build_pua.sh
cp ../scripts/ARCHIVE.LIST * ../sample/* ${workingdir}
cd ${workingdir}
tar -cvzf - -T ARCHIVE.LIST | base64 >> build_pua.sh
zip build_pua.zip build_pua.sh
shasum -a 256 build_pua.zip > build_pua.zip.sha256
shasum -a 256 build_pua.sh > build_pua.sh.sha256
cp build_pua.zip* ${script_path}/..
cp build_pua.sh* ${script_path}/../bin
