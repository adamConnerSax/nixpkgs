{ fetchFromGitHub
, stdenv
, pkgconfig
, libarchive
, glib
, # Override this to use a different revision
  src-spec ?
    { owner = "commercialhaskell";
      repo = "all-cabal-hashes";
      rev = "b490d26340638934d13c0c0cd4089dec0fb6b85e";
      sha256 = "11nyyhvwb3yd5p16cn005a4s7s7qwb0dwjb5ylz4hlhcrhqyblx8";
    }
, lib
}:

# Use builtins.fetchTarball "https://github.com/commercialhaskell/all-cabal-hashes/archive/hackage.tar.gz"
# instead if you want the latest Hackage automatically at the price of frequent re-downloads.
let partition-all-cabal-hashes = stdenv.mkDerivation
      { name = "partition-all-cabal-hashes";
        src = ./partition-all-cabal-hashes.c;
        unpackPhase = "true";
        nativeBuildInputs = [ pkgconfig ];
        buildInputs = [ libarchive glib ];
        buildPhase =
          "cc -O3 $(pkg-config --cflags --libs libarchive glib-2.0) $src -o partition-all-cabal-hashes";
        installPhase =
          ''
            mkdir -p $out/bin
            install -m755 partition-all-cabal-hashes $out/bin
          '';
      };
in fetchFromGitHub (src-spec //
  { postFetch = "${partition-all-cabal-hashes}/bin/partition-all-cabal-hashes $downloadedFile $out";
  })
