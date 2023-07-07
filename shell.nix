let
  # We specify sources via Niv: use "niv update nixpkgs" to update nixpkgs, for example.
  sources = import ./nix/sources.nix { };
in
# However, if you want to override Niv's inputs, this will let you do that.
{ pkgs ? import sources.nixpkgs { }
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
    overrides = poetry2nix.overrides.withDefaults (self: super: {
      jsonschema = super.jsonschema.overridePythonAttrs(old: {
        postPatch = ''
          sed -i "/Topic/d" pyproject.toml
        '';
      });
      jsonschema-specifications = super.jsonschema-specifications.overridePythonAttrs(old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
          self.hatchling
          self.hatch-vcs
        ];
        postPatch = ''
          sed -i "/Topic/d" pyproject.toml
        '';
      });
      pillow = super.pillow.overridePythonAttrs(old: {
        # Use preConfigure from nixpkgs to fix library detection issues and
        # impurities which can break the build process; this also requires
        # adding propagatedBuildInputs and buildInputs from the same source.
        propagatedBuildInputs = (old.buildInputs or []) ++ pkgs.python3.pkgs.pillow.propagatedBuildInputs;
        buildInputs = (old.buildInputs or []) ++ pkgs.python3.pkgs.pillow.buildInputs;
        preConfigure = (old.preConfigure or "") + pkgs.python3.pkgs.pillow.preConfigure;

        # https://github.com/nix-community/poetry2nix/issues/1139
        patches = (old.patches or []) ++ lib.optionals (old.version == "9.5.0") [
          (pkgs.fetchpatch  {
            url = "https://github.com/python-pillow/Pillow/commit/0ec0a89ead648793812e11739e2a5d70738c6be5.diff";
            sha256 = "sha256-rZfk+OXZU6xBpoumIW30E80gRsox/Goa3hMDxBUkTY0=";
          })
        ];
      });
      referencing = super.referencing.overridePythonAttrs(old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
          self.hatchling
          self.hatch-vcs
        ];
        postPatch = ''
          sed -i "/Topic/d" pyproject.toml
        '';
      });
      rpds-py = let
        getCargoHash = version: {
          "0.8.8" = "sha256-jg9oos4wqewIHe31c3DixIp6fssk742kqt4taWyOq4U=";
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
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
            pkgs.rustPlatform.cargoSetupHook
            pkgs.rustPlatform.maturinBuildHook
          ];
          buildInputs = lib.optionals stdenv.isDarwin [ libiconv ];
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
    });
  };
in
mkShell {
  name = "qmk-firmware";

  buildInputs = [ clang-tools dfu-programmer dfu-util diffutils git pythonEnv niv ]
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
