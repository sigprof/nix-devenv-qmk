let
  # We specify sources via Niv: use "niv update nixpkgs" to update nixpkgs, for example.
  sources = import ./nix/sources.nix { };
in
# However, if you want to override Niv's inputs, this will let you do that.
{ pkgs ? import sources.nixpkgs { }
, pkgs-for-clang-format ? import sources.nixpkgs-clang-format { }
, poetry2nix ? pkgs.callPackage (import sources.poetry2nix) { }
, avr ? true
, arm ? true
, teensy ? true }:
with pkgs;
let
  avrlibc = pkgsCross.avr.libcCross;

  avr_incflags = [
    "-isystem ${avrlibc}/avr/include"
    "-B${avrlibc}/avr/lib/avr5"
    "-L${avrlibc}/avr/lib/avr5"
    "-B${avrlibc}/avr/lib/avr35"
    "-L${avrlibc}/avr/lib/avr35"
    "-B${avrlibc}/avr/lib/avr51"
    "-L${avrlibc}/avr/lib/avr51"
  ];

  # Builds the python env based on nix/pyproject.toml and
  # nix/poetry.lock Use the "poetry update --lock", "poetry add
  # --lock" etc. in the nix folder to adjust the contents of those
  # files if the requirements*.txt files change
  pythonEnv = poetry2nix.mkPoetryEnv {
    projectDir = ./nix;
    overrides = [
      # Some overrides (e.g., the ones which set preferWheel) must be applied
      # before the default overrides:
      # https://github.com/nix-community/poetry2nix/pull/899
      (self: super: {
        attrs = super.attrs.override {
          # attrs >= 24.3.0 requires hatchling >= 1.26.0 to build from source:
          #   https://github.com/python-attrs/attrs/pull/1377
          #   https://github.com/pypa/hatch/issues/1715
          preferWheel = true;
        };
      })

      poetry2nix.defaultPoetryOverrides

      # Apply most overrides after the default overrides, so that things like
      # overriding cargoDeps work even when the default overrides also do that:
      # https://github.com/nix-community/poetry2nix/issues/1519
      (self: super: {
        argcomplete =
          if lib.versionAtLeast super.argcomplete.version "3.5.3"
          then
            super.argcomplete.overridePythonAttrs
              (old: {
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                  self.hatchling
                  self.hatch-vcs
                ];
              })
          else super.argcomplete;
        rpds-py = let
          getCargoHash = version: {
            "0.22.3" = "sha256-m01OB4CqDowlTAiDQx6tJ7SeP3t+EtS9UZ7Jad6Ccvc=";
          }.${version} or (
            lib.warn "Unknown rpds-py version: '${version}'. Please update getCargoHash." lib.fakeHash
          );
        in
          super.rpds-py.overridePythonAttrs(old: {
            cargoDeps = pkgs.rustPlatform.fetchCargoTarball {
              inherit (old) src;
              name = "${old.pname}-${old.version}";
              hash = getCargoHash old.version;
            };
          });
        qmk = super.qmk.overridePythonAttrs(old: {
          # Allow QMK CLI to run "qmk" as a subprocess (the wrapper changes
          # $PATH and breaks these invocations).
          dontWrapPythonPrograms = true;

          # Fix "qmk setup" to use the Python interpreter from the environment
          # when invoking "qmk doctor" (sys.executable gets its value from
          # $NIX_PYTHONEXECUTABLE, which is set by the "qmk" wrapper from the
          # Python environment, so "qmk doctor" then runs with the proper
          # $NIX_PYTHONPATH too, because sys.executable actually points to
          # another wrapper from the same Python environment).
          postPatch = ''
            substituteInPlace qmk_cli/subcommands/setup.py \
              --replace "[Path(sys.argv[0]).as_posix()" \
                "[Path(sys.executable).as_posix(), Path(sys.argv[0]).as_posix()"
          '';
        });
      })
    ];
  };
in
mkShell {
  name = "qmk-firmware";

  buildInputs = [ pkgs-for-clang-format.clang-tools_11 dfu-programmer dfu-util diffutils git pythonEnv niv ]
    ++ lib.optional avr [
      pkgsCross.avr.buildPackages.binutils
      pkgsCross.avr.buildPackages.gcc8
      avrlibc
      avrdude
    ]
    ++ lib.optional arm [ gcc-arm-embedded ]
    ++ lib.optional teensy [ teensy-loader-cli ];

  AVR_CFLAGS = lib.optional avr avr_incflags;
  AVR_ASFLAGS = lib.optional avr avr_incflags;
  shellHook = ''
    # Prevent the avr-gcc wrapper from picking up host GCC flags
    # like -iframework, which is problematic on Darwin
    unset NIX_CFLAGS_COMPILE_FOR_TARGET
  '';
}
