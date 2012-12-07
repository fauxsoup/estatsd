#!/bin/bash

NAME=estatsd
DESCRIPTION="is a statsd implementation in Erlang"

if [ -n "$1" ]; then
	working_dir=${1}
else
	working_dir=$(dirname $0)
fi

cd ${working_dir}

output_dir=/tmp
git_version=$(git log -10 --no-decorate | grep -i release | grep -Po -m1 "(\d+\.?)+([a-z]+)?")
git_sha=$(git log -1 --no-decorate | head -1 | cut -d" " -f2)

build_dir=${output_dir}/${NAME}_${git_version}
rm -rf ${build_dir} && mkdir -p ${build_dir}/DEBIAN ${build_dir}/etc/init.d ${build_dir}/usr/lib ${build_dir}/etc/${NAME}
cp -r ${working_dir}/rel/${NAME} ${build_dir}/usr/lib/
installed_size=$[$(du -s ${build_dir}/usr | cut -f1)+16]

write_control() {
cat << EOF | sed -s "s/%INSTALLED_SIZE%/${installed_size}/g;s/%GIT_VERSION%/${git_version}/g;s/%GIT_SHA%/${git_sha}/g" > ${build_dir}/DEBIAN/control
Package: ${NAME}
Priority: extra
Section: chitika
Maintainer: Anastas Semenov <asemenov@chitika.com>
Architecture: amd64
Installed-Size: %INSTALLED_SIZE%
Version: %GIT_VERSION%-1
Depends: erlang-nox(>= 1:15)
Provides: ${NAME}
Replaces: ${NAME}
Description: ${NAME^} ${DESCRIPTION}
 .
 git version %GIT_SHA%
Tag: implemented-in::erl, role::server
EOF
}

write_init_base64() {
cat << EOF | base64 -d | xz -d | sed -s "s/%NAME%/${NAME}/g" > ${build_dir}/etc/init.d/${NAME}
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
EOF

chmod 744 ${build_dir}/etc/init.d/${NAME}
}

write_config() {
cat << EOF > ${build_dir}/etc/${NAME}/cluster.config
[
 %% SASL config
 {iestatsd, [
   {flush_interval,  5000},
   {vm_metrics,      true},
   {destination,     {graphite, "localhost", 2003}}
 ]},
 {sasl, [
   {sasl_error_logger,       {file, "log/sasl-error.log"}},
   {errlog_type,              error},
   {error_logger_mf_dir,      "log/sasl"}, % Log directory
   {error_logger_mf_maxbytes, 10485760},   % 10 MB max file size
   {error_logger_mf_maxfiles, 5}           % 5 files max
 ]}
].
EOF
}

build_deb() {
dpkg -b ${build_dir} ${output_dir}/${NAME}_${git_version}-1_amd64.deb
}

write_control
write_config
write_init_base64

if build_deb; then
	echo "Debian package generated: ${output_dir}/${NAME}_${git_version}-1_amd64.deb"
	rm -rf ${build_dir}
	exit 0
else
	echo "Failed to generate Debian package, sorry.."
	exit 1
fi

