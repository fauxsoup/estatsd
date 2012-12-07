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

