# Local iroh relay server, used by the end-to-end VM test. Built from the same
# iroh fork revision Rayfish pins in Cargo.toml.
{
  lib,
  rustPlatform,
  src,
  clang,
  lld,
}:

rustPlatform.buildRustPackage {
  pname = "iroh-relay";
  version = (lib.importTOML "${src}/iroh-relay/Cargo.toml").package.version;

  inherit src;

  # The upstream workspace config selects clang + lld for x86_64-linux.
  nativeBuildInputs = [
    clang
    lld
  ];

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    outputHashes."netwatch-0.19.3" = "sha256-SDtQ68fWq/H62S3l5/Qvww0yxUE54sd0IyHCGY6LohQ=";
  };

  cargoBuildFlags = [
    "-p"
    "iroh-relay"
    "--bin"
    "iroh-relay"
    "--features"
    "server"
  ];

  doCheck = false;

  meta = {
    description = "iroh relay server";
    homepage = "https://github.com/rayfish/iroh";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "iroh-relay";
    platforms = lib.platforms.linux;
  };
}
