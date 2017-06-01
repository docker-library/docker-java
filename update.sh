#!/bin/bash
set -eo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

declare -A suites=(
	[6]='wheezy'
	[7]='jessie'
	[8]='jessie'
	[9]='sid'
)
declare -A alpineVersions=(
	[7]='3.6'
	[8]='3.6'
	#[9]='TBD' # there is no openjdk9 in Alpine yet (https://pkgs.alpinelinux.org/packages?name=openjdk9*&arch=x86_64)
)
declare -A centosVersions=(
	[6]='7'
	[7]='7'
	[8]='7'
)

declare -A addSuites=(
	[8]='jessie-backports'
	[9]='experimental'
)

declare -A variants=(
	[jre]='curl'
	[jdk]='scm'
)

declare -A debCache=()
declare -A debVerCache=()
dpkgArch="$(dpkg --print-architecture)"
debian-latest-version() {
	local package="$1"; shift
	local suite="$1"; shift

	local debVerCacheKey="$package-$suite"
	if [ -n "${debVerCache[$debVerCacheKey]:-}" ]; then
		echo "${debVerCache[$debVerCacheKey]}"
		return
	fi

	local debMirror='https://deb.debian.org/debian'
	local secMirror='http://security.debian.org'

	local remotes=( "$debMirror/dists/$suite/main" )
	case "$suite" in
		sid) ;;

		experimental)
			remotes+=( "$debMirror/dists/sid/main" )
			;;

		*-backports)
			suite="${suite%-backports}"
			remotes+=( "$debMirror/dists/$suite/main" )
			;&
		*)
			remotes+=(
				"$debMirror/dists/$suite-updates/main"
				"$secMirror/dists/$suite/updates/main"
			)
			;;
	esac

	local latestVersion= remote=
	for remote in "${remotes[@]}"; do
		if [ -z "${debCache[$remote]:-}" ]; then
			local urlBase="$remote/binary-$dpkgArch/Packages" url= decomp=
			for comp in xz bz2 gz ''; do
				if wget --quiet --spider "$urlBase.$comp"; then
					url="$urlBase.$comp"
					case "$comp" in
						xz) decomp='xz -d' ;;
						bz2) decomp='bunzip2' ;;
						gz) decomp='gunzip' ;;
						'') decomp='cat' ;;
					esac
					break
				fi
			done
			if [ -z "$url" ]; then
				continue
			fi
			debCache[$remote]="$(wget -qO- "$url" | eval "$decomp")"
		fi
		IFS=$'\n'
		local versions=( $(
			echo "${debCache[$remote]}" \
				| awk -F ': ' '
					$1 == "Package" { pkg = $2 }
					pkg == "'"$package"'" && $1 == "Version" { print $2 }
				'
		) )
		unset IFS
		local version=
		for version in "${versions[@]}"; do
			if [ -z "$latestVersion" ] || dpkg --compare-versions "$version" '>>' "$latestVersion"; then
				latestVersion="$version"
			fi
		done
	done

	debVerCache[$debVerCacheKey]="$latestVersion"
	echo "$latestVersion"
}

centos-latest-version() {
	local package="$1"; shift
	local osVersion="$1"; shift
	local mirror='' repoDbUrl='' repoDbFile='' latestVersion=''

	mirror="$(wget -qO- "http://mirrorlist.centos.org/?release=$osVersion&arch=x86_64&repo=updates" | shuf -n1)"
	repoDbFile="$(mktemp)"
	repoDbUrl="$(wget -qO- "$mirror"repodata/repomd.xml | awk -F\" '/primary.sqlite.bz2/ {print $2}')"

	wget -qO- "${mirror}${repoDbUrl}" | bunzip2 >"$repoDbFile"
	latestVersion="$(
		sqlite3 "$repoDbFile" \
			"SELECT version, release FROM packages \
				WHERE name = '$package' AND arch = 'x86_64' \
				ORDER BY version DESC LIMIT 1;" \
			| tr '|' '-'
	)"
	rm "$repoDbFile"

	echo "$latestVersion"
}

java-home-script() {
	cat <<'EOD'

# add a simple script that can auto-detect the appropriate JAVA_HOME value
# based on whether the JDK or only the JRE is installed
RUN { \
		echo '#!/bin/sh'; \
		echo 'set -e'; \
		echo; \
		echo 'dirname "$(dirname "$(readlink -f "$(which javac || which java)")")"'; \
	} > /usr/local/bin/docker-java-home \
	&& chmod +x /usr/local/bin/docker-java-home
EOD
}

travisEnv=
appveyorEnv=
for version in "${versions[@]}"; do
	javaVersion="$version" # "6-jdk"
	javaType="${javaVersion##*-}" # "jdk"
	javaVersion="${javaVersion%-*}" # "6"

	suite="${suites[$javaVersion]}"
	addSuite="${addSuites[$javaVersion]}"
	variant="${variants[$javaType]}"

	needCaHack=
	if [ "$javaVersion" -ge 8 -a "$suite" != 'sid' ]; then
		# "20140324" is broken (jessie), but "20160321" is fixed (sid)
		needCaHack=1
	fi

	debianPackage="openjdk-$javaVersion-$javaType"
	if [ "$javaType" = 'jre' -o "$javaVersion" -ge 9 ]; then
		# "openjdk-9" in Debian introduced an "openjdk-9-jdk-headless" package \o/
		debianPackage+='-headless'
	fi
	debSuite="${addSuite:-$suite}"
	debian-latest-version "$debianPackage" "$debSuite" > /dev/null # prime the cache
	debianVersion="$(debian-latest-version "$debianPackage" "$debSuite")"
	fullVersion="${debianVersion%%-*}"
	fullVersion="${fullVersion#*:}"

	echo "$version: $fullVersion (debian $debianVersion)"

	cat > "$version/Dockerfile" <<-EOD
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#

		FROM buildpack-deps:$suite-$variant

		# A few problems with compiling Java from source:
		#  1. Oracle.  Licensing prevents us from redistributing the official JDK.
		#  2. Compiling OpenJDK also requires the JDK to be installed, and it gets
		#       really hairy.
	EOD

	cat >> "$version/Dockerfile" <<'EOD'

RUN apt-get update && apt-get install -y --no-install-recommends \
		bzip2 \
		unzip \
		xz-utils \
	&& rm -rf /var/lib/apt/lists/*
EOD

	if [ "$addSuite" ]; then
		cat >> "$version/Dockerfile" <<-EOD

			RUN echo 'deb http://deb.debian.org/debian $addSuite main' > /etc/apt/sources.list.d/$addSuite.list
		EOD
	fi

	cat >> "$version/Dockerfile" <<-EOD

		# Default to UTF-8 file.encoding
		ENV LANG C.UTF-8
	EOD

	java-home-script >> "$version/Dockerfile"

	jreSuffix=
	if [ "$javaType" = 'jre' -a "$javaVersion" -lt 9 ]; then
		# woot, this hackery stopped in OpenJDK 9+!
		jreSuffix='/jre'
	fi
	cat >> "$version/Dockerfile" <<-EOD

		# do some fancy footwork to create a JAVA_HOME that's cross-architecture-safe
		RUN ln -svT "/usr/lib/jvm/java-$javaVersion-openjdk-\$(dpkg --print-architecture)" /docker-java-home
		ENV JAVA_HOME /docker-java-home$jreSuffix

		ENV JAVA_VERSION $fullVersion
		ENV JAVA_DEBIAN_VERSION $debianVersion
	EOD

	if [ "$needCaHack" ]; then
		debian-latest-version 'ca-certificates-java' "$debSuite" > /dev/null # prime the cache
		caCertHackVersion="$(debian-latest-version 'ca-certificates-java' "$debSuite")"
		cat >> "$version/Dockerfile" <<-EOD

			# see https://bugs.debian.org/775775
			# and https://github.com/docker-library/java/issues/19#issuecomment-70546872
			ENV CA_CERTIFICATES_JAVA_VERSION $caCertHackVersion
		EOD
	fi

	cat >> "$version/Dockerfile" <<EOD

RUN set -ex; \\
	\\
	apt-get update; \\
	apt-get install -y \\
		$debianPackage="\$JAVA_DEBIAN_VERSION" \\
EOD
	if [ "$needCaHack" ]; then
		cat >> "$version/Dockerfile" <<EOD
		ca-certificates-java="\$CA_CERTIFICATES_JAVA_VERSION" \\
EOD
	fi
	cat >> "$version/Dockerfile" <<EOD
	; \\
	rm -rf /var/lib/apt/lists/*; \\
	\\
# verify that "docker-java-home" returns what we expect
	[ "\$(readlink -f "\$JAVA_HOME")" = "\$(docker-java-home)" ]; \\
	\\
# update-alternatives so that future installs of other OpenJDK versions don't change /usr/bin/java
	update-alternatives --get-selections | awk -v home="\$(readlink -f "\$JAVA_HOME")" 'index(\$3, home) == 1 { \$2 = "manual"; print | "update-alternatives --set-selections" }'; \\
# ... and verify that it actually worked for one of the alternatives we care about
	update-alternatives --query java | grep -q 'Status: manual'
EOD

	if [ "$needCaHack" ]; then
		cat >> "$version/Dockerfile" <<-EOD

			# see CA_CERTIFICATES_JAVA_VERSION notes above
			RUN /var/lib/dpkg/info/ca-certificates-java.postinst configure
		EOD
	fi

	cat >> "$version/Dockerfile" <<-EOD

		# If you're reading this and have any feedback on how this image could be
		#   improved, please open an issue or a pull request so we can discuss it!
	EOD

	#
	# Alpine variant
	#

	variant='alpine'
	if [ -d "$version/$variant" ]; then
		alpineVersion="${alpineVersions[$javaVersion]}"
		alpinePackage="openjdk$javaVersion"
		alpineJavaHome="/usr/lib/jvm/java-1.${javaVersion}-openjdk"
		alpinePathAdd="$alpineJavaHome/jre/bin:$alpineJavaHome/bin"
		case "$javaType" in
			jdk)
				;;
			jre)
				alpinePackage+="-$javaType"
				alpineJavaHome+="/$javaType"
				;;
		esac

		alpineMirror="http://dl-cdn.alpinelinux.org/alpine/v${alpineVersion}/community/x86_64"
		alpinePackageVersion="$(
			wget -qO- "$alpineMirror/APKINDEX.tar.gz" \
				| tar --extract --gzip --to-stdout APKINDEX \
				| awk -F: '$1 == "P" { pkg = $2 } pkg == "'"$alpinePackage"'" && $1 == "V" { print $2 }'
		)"

		alpineFullVersion="${alpinePackageVersion/./u}"
		alpineFullVersion="${alpineFullVersion%%.*}"

		echo "$version: $alpineFullVersion (alpine $alpinePackageVersion)"

		cat > "$version/$variant/Dockerfile" <<-EOD
			#
			# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
			#
			# PLEASE DO NOT EDIT IT DIRECTLY.
			#

			FROM alpine:$alpineVersion

			# A few problems with compiling Java from source:
			#  1. Oracle.  Licensing prevents us from redistributing the official JDK.
			#  2. Compiling OpenJDK also requires the JDK to be installed, and it gets
			#       really hairy.

			# Default to UTF-8 file.encoding
			ENV LANG C.UTF-8
		EOD

		java-home-script >> "$version/$variant/Dockerfile"

		cat >> "$version/$variant/Dockerfile" <<-EOD
			ENV JAVA_HOME $alpineJavaHome
			ENV PATH \$PATH:$alpinePathAdd
		EOD
		cat >> "$version/$variant/Dockerfile" <<-EOD

			ENV JAVA_VERSION $alpineFullVersion
			ENV JAVA_ALPINE_VERSION $alpinePackageVersion
		EOD
		cat >> "$version/$variant/Dockerfile" <<EOD

RUN set -x \\
	&& apk add --no-cache \\
		${alpinePackage}="\$JAVA_ALPINE_VERSION" \\
	&& [ "\$JAVA_HOME" = "\$(docker-java-home)" ]
EOD

		travisEnv='\n  - VERSION='"$version"' VARIANT='"$variant$travisEnv"
	fi

	#
	# CentOS variant
	#

	variant='centos'
	if [ -d "$version/$variant" ]; then
		centosVersion="${centosVersions[$javaVersion]}"
		centosPackage="java-1.${javaVersion}.0-openjdk"
		centosJavaHome="/usr/lib/jvm/${centosPackage}"

		case "$javaType" in
			jdk)
				# 'devel' == JDK
				centosPackage+="-devel"
				;;
			jre)
				# 'headless' == JRE
				[ "$javaVersion" -ne 6 ] && centosPackage+="-headless"
				;;
		esac

		centosPackageVersion="$(centos-latest-version "$centosPackage" "$centosVersion")" # 1.8.0.121-0.b13.el7_3
		centosFullVersion="${centosPackageVersion%%-*}" # 1.8.0.121

		if [ "$javaVersion" -eq 6 ]; then
			centosJavaHome+="-${centosFullVersion}.x86_64"
		else
			centosJavaHome+="-${centosPackageVersion}.x86_64"
		fi
		[ "$javaType" == "jre" ] && centosJavaHome+="/$javaType"

		centosFullVersion="${javaVersion}u${centosFullVersion##*.}" # 8u121

		echo "$version: $centosFullVersion (centos $centosPackageVersion)"

		cat > "$version/$variant/Dockerfile" <<-EOD
			#
			# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
			#
			# PLEASE DO NOT EDIT IT DIRECTLY.
			#

			FROM centos:$centosVersion

			# A few problems with compiling Java from source:
			#  1. Oracle.  Licensing prevents us from redistributing the official JDK.
			#  2. Compiling OpenJDK also requires the JDK to be installed, and it gets
			#       really hairy.

			# Default to UTF-8 file.encoding
			ENV LANG C.UTF-8
		EOD

		java-home-script >> "$version/$variant/Dockerfile"

		cat >> "$version/$variant/Dockerfile" <<-EOD

			ENV JAVA_HOME $centosJavaHome
		EOD
		cat >> "$version/$variant/Dockerfile" <<-EOD

			ENV JAVA_VERSION $centosFullVersion
			ENV JAVA_CENTOS_VERSION $centosPackageVersion
		EOD
		cat >> "$version/$variant/Dockerfile" <<EOD

RUN set -x \\
	&& yum install -y \\
		${centosPackage}-"\$JAVA_CENTOS_VERSION" which \\
	&& [ "\$JAVA_HOME" = "\$(docker-java-home)" ] \\
	&& yum clean all
EOD

		travisEnv='\n  - VERSION='"$version"' VARIANT='"$variant$travisEnv"
	fi

	#
	# Windows variant
	#

	if [ -d "$version/windows" ]; then
		ojdkbuildVersion="$(
			git ls-remote --tags 'https://github.com/ojdkbuild/ojdkbuild' \
				| cut -d/ -f3 \
				| grep -E '^1[.]'"$javaVersion"'[.]' \
				| sort -V \
				| tail -1
		)"
		if [ -z "$ojdkbuildVersion" ]; then
			echo >&2 "error: '$version/windows' exists, but Java $javaVersion doesn't appear to have a corresponding ojdkbuild release"
			exit 1
		fi
		ojdkbuildZip="$(
			curl -fsSL "https://github.com/ojdkbuild/ojdkbuild/releases/tag/$ojdkbuildVersion" \
				| grep --only-matching -E 'java-'"$(echo "$ojdkbuildVersion" | cut -d. -f1-3)"'-openjdk-'"$ojdkbuildVersion"'[.][b0-9]+[.]ojdkbuild[.]windows[.]x86_64[.]zip' \
				| sort -u
		)"
		if [ -z "$ojdkbuildZip" ]; then
			echo >&2 "error: $ojdkbuildVersion doesn't appear to have the release file we need (yet?)"
			exit 1
		fi
		ojdkbuildSha256="$(curl -fsSL "https://github.com/ojdkbuild/ojdkbuild/releases/download/${ojdkbuildVersion}/${ojdkbuildZip}.sha256" | cut -d' ' -f1)"
		if [ -z "$ojdkbuildSha256" ]; then
			echo >&2 "error: $ojdkbuildVersion seems to have $ojdkbuildZip, but no sha256 for it"
			exit 1
		fi
		ojdkJavaVersion="$(echo "$ojdkbuildVersion" | cut -d. -f2,4 | cut -d- -f1 | tr . u)" # convert "1.8.0.111-3" into "8u111"

		echo "$version: $ojdkJavaVersion (windows ojdkbuild $ojdkbuildVersion)"

		sed -ri \
			-e 's/^(ENV JAVA_VERSION) .*/\1 '"$ojdkJavaVersion"'/' \
			-e 's/^(ENV JAVA_OJDKBUILD_VERSION) .*/\1 '"$ojdkbuildVersion"'/' \
			-e 's/^(ENV JAVA_OJDKBUILD_ZIP) .*/\1 '"$ojdkbuildZip"'/' \
			-e 's/^(ENV JAVA_OJDKBUILD_SHA256) .*/\1 '"$ojdkbuildSha256"'/' \
			"$version"/windows/*/Dockerfile

		for df in "$version"/windows/*/Dockerfile; do
			appveyorEnv='\n    - version: '"$version"'\n      variant: '"$(basename "$(dirname "$df")")$appveyorEnv"
		done
	fi

	travisEnv='\n  - VERSION='"$version$travisEnv"
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml

appveyor="$(awk -v 'RS=\n\n' '$1 == "environment:" { $0 = "environment:\n  matrix:'"$appveyorEnv"'" } { printf "%s%s", $0, RS }' .appveyor.yml)"
echo "$appveyor" > .appveyor.yml
