{ stdenv, lib, ghc, llvmPackages, packages
, buildPackages
, buildPlatform, hostPlatform
, ignoreCollisions ? false, withLLVM ? false
, postBuild ? ""
, haskellPackages
, ghcLibdir ? null # only used by ghcjs, when resolving plugins
}:

assert ghcLibdir != null -> (ghc.isGhcjs or false);

# This wrapper works only with GHC 6.12 or later.
assert lib.versionOlder "6.12" ghc.version || ghc.isGhcjs || ghc.isHaLVM;

# It's probably a good idea to include the library "ghc-paths" in the
# compiler environment, because we have a specially patched version of
# that package in Nix that honors these environment variables
#
#   NIX_GHC
#   NIX_GHCPKG
#   NIX_GHC_DOCDIR
#   NIX_GHC_LIBDIR
#
# instead of hard-coding the paths. The wrapper sets these variables
# appropriately to configure ghc-paths to point back to the wrapper
# instead of to the pristine GHC package, which doesn't know any of the
# additional libraries.
#
# A good way to import the environment set by the wrapper below into
# your shell is to add the following snippet to your ~/.bashrc:
#
#   if [ -e ~/.nix-profile/bin/ghc ]; then
#     eval $(grep export ~/.nix-profile/bin/ghc)
#   fi

let
  isGhcjs       = ghc.isGhcjs or false;
  isHaLVM       = ghc.isHaLVM or false;
  ghc761OrLater = isGhcjs || isHaLVM || lib.versionOlder "7.6.1" ghc.version;
  packageDBFlag = if ghc761OrLater then "--global-package-db" else "--global-conf";
  ghcCommand'    = if isGhcjs then "ghcjs" else "ghc";
  ghcCommand = "${ghc.prefix}${ghcCommand'}";
  ghcCommandCaps= lib.toUpper ghcCommand';
  libDirSuffix  = if isHaLVM then "/lib/HaLVM-${ghc.version}" else "/lib/${ghcCommand}-${ghc.version}";
  libDir        = "$out" + libDirSuffix;
  docDirSuffix  = "/share/doc/ghc/html";
  docDir        = "$out" + docDirSuffix;
  packageCfgDir = "${libDir}/package.conf.d";
  paths         = lib.filter (x: x ? isHaskellLibrary) (lib.closePropagation packages);
  hasLibraries  = lib.any (x: x.isHaskellLibrary) paths;
  # CLang is needed on Darwin for -fllvm to work:
  # https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/code-generators.html
  llvm          = lib.makeBinPath
                  ([ llvmPackages.llvm ]
                   ++ lib.optional hostPlatform.isDarwin llvmPackages.clang);
in
if paths == [] && !withLLVM then ghc else
let this = buildPackages.symlinkJoin {
  # this makes computing paths from the name attribute impossible;
  # if such a feature is needed, the real compiler name should be saved
  # as a dedicated drv attribute, like `compiler-name`
  name = ghc.name + "-with-packages";
  paths = paths ++ [ghc];
  __depsTargetTargetPropagated = packages;
  extraOutputsToInstall = [ "out" "doc" ];
  inherit ignoreCollisions;
  postBuild = ''
    . ${buildPackages.makeWrapper}/nix-support/setup-hook

    # wrap compiler executables with correct env variables

    WRAPPER_NIX_CFLAGS_LINK=""
    ${lib.optionalString stdenv.isDarwin ''
      # Find all the Framework paths that must be available at link time
      for x in "''${__pkgsTargetTarget[@]}" ; do
        if [ -d "$x/Library/Frameworks" ] ; then
          WRAPPER_NIX_CFLAGS_LINK+=" -framework-path$x/Library/Frameworks"
        fi
      done
    ''}

    for prg in ${ghcCommand} ${ghcCommand}i ${ghcCommand}-${ghc.version} ${ghcCommand}i-${ghc.version}; do
      if [[ -x "${ghc}/bin/$prg" ]]; then
        rm -f $out/bin/$prg
        makeWrapper ${ghc}/bin/$prg $out/bin/$prg                           \
          --add-flags '"-B$NIX_${ghcCommandCaps}_LIBDIR"'                   \
          --set "NIX_${ghcCommandCaps}"        "$out/bin/${ghcCommand}"     \
          --set "NIX_${ghcCommandCaps}PKG"     "$out/bin/${ghcCommand}-pkg" \
          --set "NIX_${ghcCommandCaps}_DOCDIR" "${docDir}"                  \
          --set "NIX_${ghcCommandCaps}_LIBDIR" "${libDir}"                  \
          --add-flags                          "$WRAPPER_NIX_CFLAGS_LINK"   \
          ${lib.optionalString withLLVM ''--prefix "PATH" ":" "${llvm}"''}
      fi
    done

    for prg in runghc runhaskell; do
      if [[ -x "${ghc}/bin/$prg" ]]; then
        rm -f $out/bin/$prg
        makeWrapper ${ghc}/bin/$prg $out/bin/$prg                           \
          --add-flags "-f $out/bin/${ghcCommand}"                           \
          --set "NIX_${ghcCommandCaps}"        "$out/bin/${ghcCommand}"     \
          --set "NIX_${ghcCommandCaps}PKG"     "$out/bin/${ghcCommand}-pkg" \
          --set "NIX_${ghcCommandCaps}_DOCDIR" "${docDir}"                  \
          --set "NIX_${ghcCommandCaps}_LIBDIR" "${libDir}"                  \
          --add-flags                          "$WRAPPER_NIX_CFLAGS_LINK"
      fi
    done

    for prg in ${ghcCommand}-pkg ${ghcCommand}-pkg-${ghc.version}; do
      if [[ -x "${ghc}/bin/$prg" ]]; then
        rm -f $out/bin/$prg
        makeWrapper ${ghc}/bin/$prg $out/bin/$prg --add-flags "${packageDBFlag}=${packageCfgDir}"
      fi
    done
  '' + (lib.optionalString stdenv.isDarwin ''
    # Work around a linker limit in macOS Sierra (see generic-builder.nix):
    local packageConfDir="$out/lib/${ghc.name}/package.conf.d";
    local dynamicLinksDir="$out/lib/links"
    mkdir -p $dynamicLinksDir
    # Clean up the old links that may have been (transitively) included by
    # symlinkJoin:
    rm -f $dynamicLinksDir/*
    for d in $(grep dynamic-library-dirs $packageConfDir/*|awk '{print $2}'); do
      for f in $d/*.dylib ; do
        ln -s "$f" "$dynamicLinksDir"
      done
    done
    for f in $packageConfDir/*.conf; do
      # Initially, $f is a symlink to a read-only file in one of the inputs
      # (as a result of this symlinkJoin derivation).
      # Replace it with a copy whose dynamic-library-dirs points to
      # $dynamicLinksDir
      cp $f $f-tmp
      rm $f
      sed "s,dynamic-library-dirs: .*,dynamic-library-dirs: $dynamicLinksDir," $f-tmp > $f
      rm $f-tmp
    done
  '') + ''
    ${lib.optionalString hasLibraries "$out/bin/${ghcCommand}-pkg recache"}
    ${# ghcjs will read the ghc_libdir file when resolving plugins.
      lib.optionalString (isGhcjs && ghcLibdir != null) ''
      mkdir -p "${libDir}"
      rm -f "${libDir}/ghc_libdir"
      printf '%s' '${ghcLibdir}' > "${libDir}/ghc_libdir"
    ''}
    $out/bin/${ghcCommand}-pkg check
  '' + postBuild;
  passthru = {
    preferLocalBuild = true;
    inherit (ghc) version meta;
    inherit haskellPackages;
    ghcEnvVars = {
      "NIX_${ghcCommandCaps}" = "${this.out}/bin/${ghcCommand}";
      "NIX_${ghcCommandCaps}PKG" = "${this.out}/bin/${ghcCommand}-pkg";
      "NIX_${ghcCommandCaps}_DOCDIR" = "${this.out}${docDirSuffix}";
      "NIX_${ghcCommandCaps}_LIBDIR" = "${this.out}${libDirSuffix}";
    };
  };
}; in this
