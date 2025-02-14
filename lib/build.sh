build_failed() {
  head "Build failed"
  echo ""
  cat $warnings | indent
}

build_succeeded() {
  head "Build succeeded!"
  echo ""
  (npm ls --depth=0 || true) 2>/dev/null | indent
  cat $warnings | indent
}

get_start_method() {
  local build_dir=$1
  if test -f $build_dir/Procfile; then
    echo "Procfile"
  elif [[ $(read_json "$build_dir/package.json" ".scripts.start") != "" ]]; then
    echo "npm start"
  elif test -f $build_dir/server.js; then
    echo "server.js"
  else
    echo ""
  fi
}

get_modules_source() {
  local build_dir=$1
  if test -d $build_dir/node_modules; then
    echo "prebuilt"
  elif test -f $build_dir/npm-shrinkwrap.json; then
    echo "npm-shrinkwrap.json"
  elif test -f $build_dir/package.json; then
    echo "package.json"
  else
    echo ""
  fi
}

get_modules_cached() {
  local cache_dir=$1
  if test -d $cache_dir/node/node_modules; then
    echo "true"
  else
    echo "false"
  fi
}

# Sets:
# iojs_engine
# semver_range
# npm_engine
# start_method
# modules_source
# npm_previous
# node_previous
# modules_cached
# environment variables (from ENV_DIR)

read_current_state() {
  info "package.json..."
  assert_json "$build_dir/package.json"
  semver_range=$(read_json "$build_dir/package.json" ".engines.node")
  npm_engine=$(read_json "$build_dir/package.json" ".engines.npm")

  info "build directory..."
  start_method=$(get_start_method "$build_dir")
  modules_source=$(get_modules_source "$build_dir")

  info "cache directory..."
  bp_previous=$(file_contents "$cache_dir/node/bp-version")
  npm_previous=$(file_contents "$cache_dir/node/npm-version")
  node_previous=$(file_contents "$cache_dir/node/node-version")
  modules_cached=$(get_modules_cached "$cache_dir")

  info "environment variables..."
  if [ -d "$env_dir" ]; then
    export_env_dir $env_dir
  fi

  export NPM_CONFIG_PRODUCTION=${NPM_CONFIG_PRODUCTION:-true}
  export NODE_MODULES_CACHE=${NODE_MODULES_CACHE:-true}
}

show_current_state() {
  echo ""
  info "Node engine range:   ${semver_range:-unspecified}"
  info "Npm engine:          ${npm_engine:-unspecified}"
  info "Start mechanism:     ${start_method:-none}"
  info "node_modules source: ${modules_source:-none}"
  info "node_modules cached: $modules_cached"
  echo ""

  printenv | grep ^NPM_CONFIG_ | indent
  info "NODE_MODULES_CACHE=$NODE_MODULES_CACHE"
}

install_node() {
  local semver_range=$1

  # Resolve non-specific node versions using semver.herokuapp.com

  if is_cached
  then
    node_engine=$($bp_dir/bin/node $bp_dir/lib/version_resolver.js "$semver_range")
  else
    node_engine=$(curl --silent --get --data-urlencode "range=${semver_range}" https://semver.io/node/resolve)
  fi

  # Download node from Heroku's S3 mirror of nodejs.org/dist
  info "Downloading and installing node $node_engine..."
  node_url="http://s3pository.heroku.com/node/v$node_engine/node-v$node_engine-linux-x64.tar.gz"
  (curl `translate_dependency_url $node_url` -s --fail -o - | tar xzf - -C $build_dir)  || (echo -e "\n-----> Resource $node_url does not exist." 1>&2 ; exit 22)

  # Move node (and npm) into .heroku/node and make them executable
  mkdir -p $build_dir/vendor
  mv $build_dir/node-v$node_engine-linux-x64 $build_dir/vendor/node
  chmod +x $build_dir/vendor/node/bin/*
  PATH=$build_dir/vendor/node/bin:$PATH
}

install_iojs() {
  local iojs_engine=$1

  # Resolve non-specific iojs versions using semver.herokuapp.com
  if ! [[ "$iojs_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "Resolving iojs version ${iojs_engine:-(latest stable)} via semver.io..."
    iojs_engine=$(curl --silent --get --data-urlencode "range=${iojs_engine}" https://semver.herokuapp.com/iojs/resolve)
  fi

  # TODO: point at /dist once that's available
  info "Downloading and installing iojs $iojs_engine..."
  download_url="https://iojs.org/dist/v$iojs_engine/iojs-v$iojs_engine-linux-x64.tar.gz"
  curl $download_url -s -o - | tar xzf - -C /tmp

  # Move iojs/node (and npm) binaries into .heroku/node and make them executable
  mv /tmp/iojs-v$iojs_engine-linux-x64/* $heroku_dir/node
  chmod +x $heroku_dir/node/bin/*
  PATH=$heroku_dir/node/bin:$PATH
}

install_npm() {
  # Optionally bootstrap a different npm version
  if [ "$npm_engine" != "" ]; then
    if ! [[ "$npm_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      info "Resolving npm version ${npm_engine} via semver.io..."
      npm_engine=$(curl --silent --get --data-urlencode "range=${npm_engine}" https://semver.herokuapp.com/npm/resolve)
    fi
    if [[ `npm --version` == "$npm_engine" ]]; then
      info "npm `npm --version` already installed with node"
    else
      info "Downloading and installing npm $npm_engine (replacing version `npm --version`)..."
      npm install --unsafe-perm --quiet -g npm@$npm_engine 2>&1 >/dev/null | indent
    fi
    warn_old_npm `npm --version`
  else
    info "Using default npm version: `npm --version`"
  fi
}

build_dependencies() {
  restore_cache

  if [ "$modules_source" == "" ]; then
    info "Skipping dependencies (no source for node_modules)"

  elif [ "$modules_source" == "prebuilt" ]; then
    info "Rebuilding any native modules for this architecture"
    npm rebuild 2>&1 | indent

  else
    info "Installing node modules"
    npm install --unsafe-perm --quiet --userconfig $build_dir/.npmrc 2>&1 | indent
  fi
}

ensure_procfile() {
  local start_method=$1
  local build_dir=$2
  if [ "$start_method" == "Procfile" ]; then
    info "Found Procfile"
  elif test -f $build_dir/Procfile; then
    info "Procfile created during build"
  elif [ "$start_method" == "npm start" ]; then
    info "No Procfile; Adding 'web: npm start' to new Procfile"
    echo "web: npm start" > $build_dir/Procfile
  elif [ "$start_method" == "server.js" ]; then
    info "No Procfile; Adding 'web: node server.js' to new Procfile"
    echo "web: node server.js" > $build_dir/Procfile
  else
    info "None found"
  fi
}

write_profile() {
  info "Creating runtime environment"
  mkdir -p $build_dir/.profile.d
# echo "export PATH=\"\$HOME/vendor/node/bin:\$HOME/bin:\$HOME/node_modules/.bin:\$PATH\"" > $build_dir/.profile.d/nodejs.sh
  echo "export PATH=\"\$HOME/vendor/imagemagick/usr/bin:\$HOME/vendor/node/bin:\$HOME/bin:\$HOME/node_modules/.bin:\$PATH\"" > $build_dir/.profile.d/nodejs.sh
  echo "export LD_LIBRARY_PATH=\"\$HOME/vendor/imagemagick/libs:\$HOME/vendor/imagemagick/usr/libs:\$LD_LIBRARY_PATH\";" >> $build_dir/.profile.d/nodejs.sh
  echo "export NODE_HOME=\"\$HOME/vendor/node\"" >> $build_dir/.profile.d/nodejs.sh
}

write_export() {
  info "Exporting binary paths"
  echo "export PATH=\"$build_dir/.heroku/node/bin:$build_dir/node_modules/.bin:\$PATH\"" > $bp_dir/export
  echo "export NODE_HOME=\"$build_dir/.heroku/node\"" >> $bp_dir/export
}

clean_npm() {
  info "Cleaning npm artifacts"
  rm -rf "$build_dir/.node-gyp"
  rm -rf "$build_dir/.npm"
}

# Caching

create_cache() {
  info "Caching results for future builds"
  mkdir -p $cache_dir/node

  echo `node --version` > $cache_dir/node/node-version
  echo `npm --version` > $cache_dir/node/npm-version

  if test -d $build_dir/node_modules; then
    cp -r $build_dir/node_modules $cache_dir/node
  fi
  write_user_cache
}

clean_cache() {
  info "Cleaning previous cache"
  rm -rf "$cache_dir/node_modules" # (for apps still on the older caching strategy)
  rm -rf "$cache_dir/node"
}

get_cache_status() {
  local node_version=`node --version`
  local npm_version=`npm --version`

  # Did we bust the cache?
  if ! $modules_cached; then
    echo "No cache available"
  elif ! $NODE_MODULES_CACHE; then
    echo "Cache disabled with NODE_MODULES_CACHE"
  elif [ "$node_previous" != "" ] && [ "$node_version" != "$node_previous" ]; then
    echo "Node version changed ($node_previous => $node_version); invalidating cache"
  elif [ "$npm_previous" != "" ] && [ "$npm_version" != "$npm_previous" ]; then
    echo "Npm version changed ($npm_previous => $npm_version); invalidating cache"
  else
    echo "valid"
  fi
}

restore_cache() {
  local directories=($(cache_directories))
  cache_status=$(get_cache_status)

  if [ "$directories" != -1 ]; then
    info "Restoring ${#directories[@]} directories from cache:"
    for directory in "${directories[@]}"
    do
      local source_dir="$cache_dir/node/$directory"
      if [ -e $source_dir ]; then
        if [ "$directory" == "node_modules" ]; then
          restore_npm_cache
        else
          info "- $directory"
          cp -r $source_dir $build_dir/
        fi
      fi
    done
  elif [ "$cache_status" == "valid" ]; then
    restore_npm_cache
    info "$cache_status"
  else
    touch $build_dir/.npmrc
  fi
}

restore_npm_cache() {
  info "Restoring node modules from cache"
  cp -r $cache_dir/node/node_modules $build_dir/
  info "Pruning unused dependencies"
  npm --unsafe-perm prune 2>&1 | indent
}

cache_directories() {
  local package_json="$build_dir/package.json"
  local key=".cache_directories"
  local check=$(key_exist $package_json $key)
  local result=-1
  if [ "$check" != -1 ]; then
    result=$(read_json "$package_json" "$key[]")
  fi
  echo $result
}

key_exist() {
  local file=$1
  local key=$2
  local output=$(read_json $file $key)
  if [ -n "$output" ]; then
    echo 1
  else
    echo -1
  fi
}

write_user_cache() {
  local directories=($(cache_directories))
  if [ "$directories" != -1 ]; then
    info "Storing directories:"
    for directory in "${directories[@]}"
    do
      info "- $directory"
      cp -r $build_dir/$directory $cache_dir/node/
    done
  fi
}

install_imagemagick() {
  info "Installing ImageMagick"
  
  #cd $bp_dir/image_magick
  #tar xvzf ImageMagick.tar.gz
  #cd ImageMagick-6.9.1-2
  #./configure --without-magick-plus-plus --without-perl --with-apple-font-dir=none --with-dejavu-font-dir= none --with-gs-font-dir= none --with-windows-font-dir= none --prefix=$build_dir/vendor/imagemagick
  #make
  #make install

  mkdir -p $build_dir/vendor/imagemagick
  tar xzf $bp_dir/vendor/ImageMagick_Ubuntu-10.04.tar.gz -C $build_dir/vendor/imagemagick
  chmod +x $build_dir/vendor/imagemagick/usr/bin/*
}
