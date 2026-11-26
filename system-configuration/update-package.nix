{
  config,
  pkgs,
  ...
}:

let
  inherit (config.system) build;
  inherit (config.system.image) version id;
in

{
  config.system.build.sysupdate-package =
    pkgs.runCommand "sysupdate-package-${config.system.image.version}"
      {
        nativeBuildInputs = [ pkgs.zstd ];
      }
      ''
        mkdir -p $out
        cp ${build.uki}/${config.system.boot.loader.ukiFile} $out/
        if [ -f ${build.image}/${id}_${version}.nix-store.raw.zst ]; then
          cp ${build.image}/${id}_${version}.nix-store.raw.zst $out/
        else
          zstd -T0 -4 ${build.image}/${id}_${version}.nix-store.raw -o $out/${id}_${version}.nix-store.raw.zst
        fi
        if [ -f ${build.image}/${id}_${version}.raw.zst ]; then
          cp ${build.image}/${id}_${version}.raw.zst $out/
        else
          zstd -T0 -4 ${build.image}/${id}_${version}.raw -o $out/${id}_${version}.raw.zst
        fi
        cd $out
        sha256sum * > SHA256SUMS
      '';
}
