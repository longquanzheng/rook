#!/bin/bash -e

scriptdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source ${scriptdir}/common.sh

registry=${RELEASE_REGISTRY}/

get_image_name() {
    local os=$1
    local arch=$2
    local repo=$3
    local version=$4

    local tag=${repo}-${arch}:${version}
    if [[ ${arch} == "amd64" ]]; then
        tag=${repo}:${version}
    fi

    echo ${tag}
}

build_artifact() {
    local os=$1
    local arch=$2
    local tmpdir=$3
    local repo=$4

    shift 4
    local bins="$@"

    layout_root $os $arch $tmpdir $bins
    mkdir $tmpdir/root/tmp

    local name=$(get_image_name $os $arch $repo ${RELEASE_VERSION})

    local docker_no_cache=
    if [[ ${RELEASE_CHANNEL} != "" ]]; then
        docker_no_cache=--no-cache
    fi

    echo building docker container ${name}
    docker build --pull ${docker_no_cache} -t ${registry}${name} $tmpdir

    local file=${name/\//-}
    local file=${file/:/-}
    local dockerout=${file}.docker
    echo ${file}

    echo generate ACIs from docker containers
    (cd ${RELEASE_DIR} && docker save -o ${dockerout} ${registry}${name})
    (cd ${RELEASE_DIR} && docker2aci ${dockerout})
}

build() {
    local os=$1
    local arch=$2

    [[ ${os} == "linux" ]] || return 0

    local baseimage=UNSUPPORTED
    case ${arch} in
        arm) baseimage=armhf/alpine ;;
        amd64) baseimage=alpine ;;
        arm64) baseimage=aarch64/alpine ;;
    esac

    echo "Building the rookd container"
    tmpdir=$(mktemp -d)
    trap "rm -fr $tmpdir" EXIT
    cat <<EOF > $tmpdir/Dockerfile
FROM ${baseimage}:3.5
RUN apk add --no-cache gptfdisk util-linux coreutils e2fsprogs
COPY root /
ENTRYPOINT ["/usr/bin/rookd"]
EOF
    build_artifact $os $arch $tmpdir rook/rookd rookd
    rm -fr $tmpdir
 
    echo "Building the rook client container"
    mkdir $tmpdir
    cat <<EOF > $tmpdir/Dockerfile
FROM ${baseimage}:3.5
RUN apk add --no-cache e2fsprogs
COPY root /
ENTRYPOINT ["/usr/bin/rook"]
EOF
    build_artifact $os $arch $tmpdir rook/rook rook
    rm -fr $tmpdir

    # TODO: build the toolbox for arm
    [[ ${os} != "amd64" ]] || return 0
 
    echo "Building the toolbox container"
    mkdir $tmpdir
    cp toolbox/entrypoint.sh $tmpdir
    eval "cat <<EOF
$(<toolbox/Dockerfile)
EOF
" >$tmpdir/Dockerfile
    build_artifact $os $arch $tmpdir rook/toolbox rook
    rm -fr $tmpdir
}

publish_artifact() {
    local os=$1
    local arch=$2
    local repo=$3

    local name=${registry}$(get_image_name $os $arch $repo ${RELEASE_VERSION})

    echo pushing docker container ${name}
    docker push ${name}

    # we will always tag master builds as latest. i.e. auto-promote master
    if [[ "${RELEASE_CHANNEL}" == "master" ]]; then
        local dst=${registry}$(get_image_name $os $arch $repo master-latest)
        echo pushing docker container ${dst}
        docker tag ${name} ${dst}
        docker push ${dst}
    fi
}

publish() {
    local os=$1
    local arch=$2

    [[ ${os} == "linux" ]] || return 0

    publish_artifact $os $arch rook/rookd 
    publish_artifact $os $arch rook/rook

    # TODO: publish the toolbox for arm
    [[ ${arch} == "amd64" ]] || return 0
    publish_artifact $os $arch rook/toolbox
}

promote_artifact() {
    local os=$1
    local arch=$2
    local repo=$3

    local src=${registry}$(get_image_name $os $arch $repo ${RELEASE_VERSION})
    local dst1=${registry}$(get_image_name $os $arch $repo ${RELEASE_CHANNEL}-latest)
    local dst2=${registry}$(get_image_name $os $arch $repo ${RELEASE_CHANNEL}-${RELEASE_VERSION})

    echo promoting container ${src} to ${dst1} and ${dst2}
    docker pull ${src}
    docker tag ${src} ${dst1}
    docker tag ${src} ${dst2}
    docker push ${dst1}
    docker push ${dst2}
}

promote() {
    local os=$1
    local arch=$2

    [[ ${os} == "linux" ]] || return 0

    promote_artifact $os $arch rook/rookd
    promote_artifact $os $arch rook/rook
    promote_artifact $os $arch rook/toolbox
}

cleanup_artifact() {
    local os=$1
    local arch=$2
    local repo=$3
    local img

    for t in \
        ${RELEASE_VERSION} \
        ${RELEASE_CHANNEL}-latest \
        ${RELEASE_CHANNEL}-${RELEASE_VERSION} \
        ; do
        img=${registry}$(get_image_name $os $arch $repo ${t})
        if [[ -n "$(docker images -q ${img} 2> /dev/null)" ]]; then
            echo removing docker image ${img}
            docker rmi ${img} || true
        fi
    done
}

cleanup() {
    local os=$1
    local arch=$2

    [[ ${os} == "linux" ]] || return 0
    cleanup_artifact $os $arch rook/rookd
    cleanup_artifact $os $arch rook/rook
    cleanup_artifact $os $arch rook/toolbox
}

action=$1
shift

${action} "$@"
