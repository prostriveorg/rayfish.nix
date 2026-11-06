# Nixpkgs-style derivation for the ray CLI/daemon. `src` is the pinned upstream
# source tree (the flake passes its rayfish-src input).
{
  lib,
  rustPlatform,
  src,
  gitSha ? "unknown",
}:

rustPlatform.buildRustPackage {
  pname = "rayfish";
  version = (lib.importTOML "${src}/Cargo.toml").package.version;

  inherit src;

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    # The [patch.crates-io] git dependencies. When upstream moves a fork or
    # changes a rev, replace the affected hashes with lib.fakeHash, build, and
    # copy the "got:" hash from the error.
    outputHashes = {
      "iroh-1.3.0" = "sha256-sStcLLhmojsm8Xf3OVr5Qj64bQmUiZl0DOtpPY1AwmU=";
      "iroh-base-1.3.0" = "sha256-sStcLLhmojsm8Xf3OVr5Qj64bQmUiZl0DOtpPY1AwmU=";
      "iroh-dns-1.3.0" = "sha256-sStcLLhmojsm8Xf3OVr5Qj64bQmUiZl0DOtpPY1AwmU=";
      "iroh-relay-1.3.0" = "sha256-sStcLLhmojsm8Xf3OVr5Qj64bQmUiZl0DOtpPY1AwmU=";
      "iroh-mdns-address-lookup-0.6.0" = "sha256-zqILvQXVOLJskNi51z9D/7EzDOVm74k0jPS49glf4b0=";
      "netdev-0.46.3" = "sha256-5mJIDDdOjd7mqKzaWg+8jAaxT77gtFeLbSqd7s+ZVgI=";
      "netwatch-0.19.3" = "sha256-IcrcFR1kd+oOoAa4eoB2qAUUWj1f2qjXUPTTJ16v9LY=";
      "tun-rs-2.8.11" = "sha256-tMOR7A4iS8PlTRpsiTrzzSFWte22Xi9WmjeucLs1Now=";
    };
  };

  # Build only the desktop CLI/daemon binary. ray-mobile is Android-only.
  cargoBuildFlags = [
    "--bin"
    "ray"
  ];

  # Upstream tests require network access; the Nix sandbox has none. Keeping
  # checks off makes a derivation failure mean packaging broke.
  doCheck = false;

  # build.rs stamps the git short SHA into the binary. There is no .git in the
  # sandbox, so prefer the flake-provided value when the git command fails.
  postPatch = ''
    substituteInPlace build.rs \
      --replace-fail '.filter(|s| !s.is_empty())' \
      '.filter(|s| !s.is_empty()).or_else(|| env::var("RAY_GIT_SHA").ok())'
  '';

  env.RAY_GIT_SHA = gitSha;

  meta = {
    description = "P2P mesh VPN powered by iroh";
    homepage = "https://github.com/rayfish/rayfish";
    license = lib.licenses.mpl20;
    mainProgram = "ray";
    platforms = lib.platforms.linux;
  };
}
