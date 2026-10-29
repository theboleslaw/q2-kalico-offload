# n3oney/qidi-q2-klipper Nix build (vendored for provenance)

This directory holds the Nix expressions and inputs from
`https://github.com/n3oney/qidi-q2-klipper` (commit pinned by the bundle at
vendor time). They are the upstream build for the Kalico variant used by this
bundle: the Kalico patch series, MCU configs and Happy Hare patches under
`nix/` are the source of the files installed into `q2-klipper/patches/`,
`q2-klipper/firmware/configs/` and `vendor/firmware/`.

Nothing here is used by `install-klipper.sh`. The installer builds or uses the
prebuilt firmware in `vendor/firmware/`. Keep this directory for reproducibility
and to regenerate firmware with Nix if desired:

    cd vendor/n3oney
    nix build .#kalico-bleeding-edge.full
    nix build .#kalico-bleeding-edge.firmwares.all
