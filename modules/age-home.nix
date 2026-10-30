{
  config,
  options,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.age;
  verbosityLevel =
    {
      quiet = 0;
      summary = 1;
      progress = 2;
      detailed = 3;
    }
    .${cfg.verbosity};

  ageBin = lib.getExe config.age.package;

  mapListOrAttrs = f: x: if builtins.isList x then map f x else lib.mapAttrs (_: f) x;
  mapListOrAttrsToList = f: x: if builtins.isList x then map f x else lib.mapAttrsToList (_: f) x;

  # Subdirectory NAMES inside a generation. See the equivalent note in ./age.nix:
  # secrets and templates each get their own directory so `age.secretsDir` and
  # `age.templateDir` are two independent symlinks into one generation.
  secretsSubdir = "secrets";
  templatesSubdir = "templates";

  # `secretsDir` points at <gen>/secrets, so the generation is one level further
  # up. The numeric guard matters on a first activation, where the symlink does
  # not exist and `basename "$(dirname "")"` is "." rather than a number.
  currentGeneration = ''
    _agenix_generation="$(basename "$(dirname "$(readlink "${cfg.secretsDir}")")" || echo 0)"
    if ! [[ "$_agenix_generation" =~ ^[0-9]+$ ]]; then
      _agenix_generation=0
    fi
  '';

  newGeneration = ''
    ${currentGeneration}
    (( ++_agenix_generation ))
    ${optionalString (
      verbosityLevel >= 2
    ) ''echo "[agenix] creating new generation in ${cfg.ageMountPoint}/$_agenix_generation"''}
    mkdir -p "${cfg.ageMountPoint}"
    chmod 0751 "${cfg.ageMountPoint}"
    mkdir -p "${cfg.ageMountPoint}/$_agenix_generation"
    chmod 0751 "${cfg.ageMountPoint}/$_agenix_generation"
    mkdir -p "${cfg.ageMountPoint}/$_agenix_generation/${secretsSubdir}"
    mkdir -p "${cfg.ageMountPoint}/$_agenix_generation/${templatesSubdir}"
    mkdir -p "$(dirname "${cfg.secretsDir}")"
    mkdir -p "$(dirname "${cfg.templateDir}")"
  '';

  # The agenix managed directory a secret or template is exposed through, and
  # the subdirectory of that directory inside a generation.
  targetDir =
    secretType: toString (if secretType.type == "template" then cfg.templateDir else cfg.secretsDir);
  subdirOf = secretType: if secretType.type == "template" then templatesSubdir else secretsSubdir;

  # Whether path points inside the agenix managed directory. That directory is
  # itself a symlink which only points at the new generation once everything is
  # installed, so such files cannot be written to path directly: they would land
  # in the previous generation and be removed together with it. They are created
  # in the new generation instead, keeping any nested folders of path.
  inTargetDir = secretType: hasPrefix "${targetDir secretType}/" secretType.path;

  # Location of the file inside a generation, relative to its subdirectory.
  generationPath =
    secretType:
    if inTargetDir secretType then
      removePrefix "${targetDir secretType}/" secretType.path
    else
      secretType.name;

  setTruePath = secretType: ''
    ${
      if secretType.symlink || inTargetDir secretType then
        ''
          _truePath="${cfg.ageMountPoint}/$_agenix_generation/${subdirOf secretType}/${
            generationPath secretType
          }"
        ''
      else
        ''
          _truePath="${secretType.path}"
        ''
    }
  '';

  # Files outside of the managed directory are symlinked into place. Files
  # inside it are already reachable through the directory symlink itself.
  linkToPath =
    secretType:
    optionalString (secretType.symlink && !inTargetDir secretType) ''
      mkdir -p "$(dirname "${secretType.path}")"
      ln -sfT "${targetDir secretType}/${secretType.name}" "${secretType.path}"
    '';

  setupStart = secretType: ''
    ${setTruePath secretType}
    ${optionalString (
      verbosityLevel >= 3
    ) ''echo "setting up ${secretType.type} '${secretType.name}' at '$_truePath'..."''}
    TMP_FILE="$_truePath.tmp"
    IDENTITIES=()
    _agenix_identity_paths=( ${toString cfg.identityPaths} )
    for identity in "''${_agenix_identity_paths[@]}"; do
      test -r "$identity" || continue
      IDENTITIES+=(-i)
      IDENTITIES+=("$identity")
    done

    test "''${#IDENTITIES[@]}" -eq 0 && echo "[agenix] WARNING: no readable identities found!" >&2

    mkdir -p "$(dirname "$_truePath")"
  '';

  recordRestarts = secretType: ''
    ${concatStringsSep "\n" (map (unit: "UNITS_TO_RESTART+=('${unit}')") secretType.restartUnits)}
  '';

  ifChanged = secretType: ''
    if [ -f "$_truePath" ]; then
      if ${pkgs.diffutils}/bin/cmp -s "$_truePath" "$TMP_FILE"; then
        :
      else
        ${optionalString (verbosityLevel >= 3) ''echo "${secretType.type} ${secretType.name} changed."''}
        ${recordRestarts secretType}
      fi
    else
      ${optionalString (verbosityLevel >= 3) ''echo "${secretType.type} ${secretType.name} is new."''}
      ${recordRestarts secretType}
    fi
  '';

  installSecret = secretType: ''
    ${setupStart secretType}
    ${optionalString (
      verbosityLevel >= 3
    ) ''echo "decrypting '${secretType.file}' to '$_truePath'..."''}
    (
      umask u=r,g=,o=
      test -f "${secretType.file}" || echo '[agenix] WARNING: encrypted file ${secretType.file} does not exist!' >&2
      test -d "$(dirname "$TMP_FILE")" || echo "[agenix] WARNING: $(dirname "$TMP_FILE") does not exist!" >&2
      LANG=${
        config.i18n.defaultLocale or "C"
      } ${ageBin} --decrypt "''${IDENTITIES[@]}" -o "$TMP_FILE" "${secretType.file}"
    )

    ${ifChanged secretType}

    chmod ${secretType.mode} "$TMP_FILE"
    mv -f "$TMP_FILE" "$_truePath"

    ${linkToPath secretType}
  '';

  installTemplate = templateType: ''
    ${setupStart templateType}
    ${optionalString (
      verbosityLevel >= 3
    ) ''echo "generating template '${templateType.name}' to '$_truePath'..."''}
    cp ${templateType.file} "$TMP_FILE"

    ${builtins.concatStringsSep "\n" (
      lib.flip mapListOrAttrsToList templateType.placeholderMap (dep: ''
        ${optionalString (
          verbosityLevel >= 3
        ) ''echo "replacing placeholder ${dep.placeholder} in ${templateType.name}..."''}
        test -f "${dep.file}" || echo "[agenix] WARNING: dependency file ${dep.file} does not exist!" >&2

        _secret=$(${ageBin} --decrypt "''${IDENTITIES[@]}" ${lib.escapeShellArg dep.file})
        _secret="''${_secret//\\/\\\\}"
        _secret="''${_secret//|/\\|}"
        _secret="''${_secret//&/\\&}"
        _secret="''${_secret//$'\n'/\\n}"
        ${pkgs.gnused}/bin/sed -i.bak "s|${dep.placeholder}|''${_secret}|g" "$TMP_FILE"
        rm -f "$TMP_FILE.bak"
      '')
    )}

    ${ifChanged templateType}

    chmod ${templateType.mode} "$TMP_FILE"
    mv -f "$TMP_FILE" "$_truePath"

    ${linkToPath templateType}
  '';

  testIdentities = map (path: ''
    test -f ${path} || echo '[agenix] WARNING: config.age.identityPaths entry ${path} not present!' >&2
  '') cfg.identityPaths;

  cleanupAndLink = ''
    ${currentGeneration}
    (( ++_agenix_generation ))
    ${optionalString (verbosityLevel >= 2)
      ''echo "[agenix] symlinking new secrets to ${cfg.secretsDir} (generation $_agenix_generation)..."''
    }
    ln -sfT "${cfg.ageMountPoint}/$_agenix_generation/${secretsSubdir}" "${cfg.secretsDir}"
    ${optionalString (verbosityLevel >= 2)
      ''echo "[agenix] symlinking new templates to ${cfg.templateDir} (generation $_agenix_generation)..."''
    }
    ln -sfT "${cfg.ageMountPoint}/$_agenix_generation/${templatesSubdir}" "${cfg.templateDir}"

    (( _agenix_generation > 1 )) && {
    ${optionalString (
      verbosityLevel >= 2
    ) ''echo "[agenix] removing old secrets (generation $(( _agenix_generation - 1 )))..."''}
    rm -rf "${cfg.ageMountPoint}/$(( _agenix_generation - 1 ))"
    }
  '';

  enabledSecrets = lib.filter (secret: secret.enable) (builtins.attrValues cfg.secrets);
  enabledTemplates = lib.filter (template: template.enable) (builtins.attrValues cfg.templates);

  # No chown step here -- a home-manager activation owns everything it writes --
  # so unlike ./age.nix the restarts happen inline rather than through a file
  # handed to a second unit.
  installSecrets = builtins.concatStringsSep "\n" (
    (optional (verbosityLevel >= 1) "echo '[agenix] decrypting secrets...'")
    ++ [ "UNITS_TO_RESTART=()" ]
    ++ testIdentities
    ++ (map installSecret enabledSecrets)
    ++ (map installTemplate enabledTemplates)
    ++ [
      cleanupAndLink
      ''
        if [ "''${#UNITS_TO_RESTART[@]}" -ne 0 ]; then
          mapfile -t UNIQUE_UNITS < <(printf "%s\n" "''${UNITS_TO_RESTART[@]}" | sort -u)
          ${optionalString (verbosityLevel >= 1) ''echo "[agenix] restarting units: ''${UNIQUE_UNITS[*]}"''}
          if [ "$(uname)" = "Darwin" ]; then
            for unit in "''${UNIQUE_UNITS[@]}"; do
              launchctl kickstart -k "gui/$(id -u)/$unit" || true
            done
          else
            systemctl --user try-restart "''${UNIQUE_UNITS[@]}"
          fi
        fi
      ''
    ]
  );

  # Options shared by a secret and a template.
  commonOptions = config: name: {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to install this file.";
    };
    name = mkOption {
      type = types.str;
      default = name;
      description = ''
        Name of the file used in ''${cfg.secretsDir} or ''${cfg.templateDir}
      '';
    };
    mode = mkOption {
      type = types.str;
      default = "0400";
      description = ''
        Permissions mode of the installed file in a format understood by chmod.
      '';
    };
    restartUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        List of user units to restart when this file's contents change. Compared
        with `cmp` against the previous generation, so an unchanged file
        restarts nothing.
      '';
    };
  };

  secretType = types.submodule (
    {
      config,
      name,
      ...
    }:
    {
      options = commonOptions config name // {
        type = mkOption {
          type = types.enum [ "secret" ];
          readOnly = true;
          internal = true;
          default = "secret";
        };
        file = mkOption {
          type = types.path;
          description = ''
            Age file the secret is loaded from.
          '';
        };
        path = mkOption {
          type = types.str;
          default = "${cfg.secretsDir}/${config.name}";
          description = ''
            Path where the decrypted secret is installed.
          '';
        };
        symlink = mkEnableOption "symlinking secrets to their destination" // {
          default = true;
        };
      };
    }
  );

  templateType = types.submodule (
    {
      config,
      name,
      ...
    }:
    {
      options = commonOptions config name // {
        type = mkOption {
          type = types.enum [ "template" ];
          readOnly = true;
          internal = true;
          default = "template";
        };
        dependencies = mkOption {
          type =
            with types;
            oneOf [
              (listOf unspecified)
              (attrsOf unspecified)
            ];
          default = [ ];
          description = ''
            Other secrets on which this template depends. Their decrypted
            plaintext is substituted into the rendered content at activation
            time, via the opaque markers passed to `content` as `placeholders`.
          '';
        };
        content = mkOption {
          type = types.functionTo (types.str);
          description = ''
            Function producing the template's text. Called with `pkgs`, `lib` and
            `placeholders` -- the last matching the shape of `dependencies`.
          '';
        };
        path = mkOption {
          type = types.str;
          default = "${cfg.templateDir}/${config.name}";
          description = "The path where the generated file will be written to.";
        };
        placeholderMap = mkOption {
          type = types.attrsOf types.attrs;
          default = mapListOrAttrs (
            dep:
            dep
            // {
              placeholder = "<AGE_PLACEHOLDER:${builtins.hashString "sha256" dep.name}:${
                builtins.hashString "sha256" (toString dep.file)
              }:>";
            }
          ) config.dependencies;
          internal = true;
          readOnly = true;
          description = ''
            Placeholders to be used in the content script. Each placeholder key will be
            replaced by its corresponding value in the final generated secret content.
          '';
        };
        file = mkOption {
          type = types.path;
          readOnly = true;
          internal = true;
          default = "${pkgs.writeTextFile {
            name = "agenix-template-${config.name}-content";
            text = config.content {
              pkgs = pkgs;
              lib = lib;
              placeholders = mapListOrAttrs (dep: dep.placeholder) config.placeholderMap;
            };
          }}";
          defaultText = literalExpression ''
            pkgs.writeTextFile {
              name = "agenix-template-''${config.name}-content";
              text = config.content { inherit pkgs lib; placeholders = ...; };
            }
          '';
          description = "The rendered template, with placeholders still in it.";
        };
        symlink = mkEnableOption "symlinking templates to their destination" // {
          default = true;
        };
      };
    }
  );

  mountingScript =
    let
      app = pkgs.writeShellApplication {
        name = "agenix-home-manager-mount-secrets";
        runtimeInputs = with pkgs; [
          coreutils
          diffutils
          gnused
        ];
        text = ''
          ${newGeneration}
          ${installSecrets}
          exit 0
        '';
      };
    in
    lib.getExe app;

  userDirectory =
    dir:
    let
      inherit (pkgs.stdenv.hostPlatform) isDarwin;
      baseDir =
        if isDarwin then "$(${lib.getExe pkgs.getconf} DARWIN_USER_TEMP_DIR)" else "\${XDG_RUNTIME_DIR}";
    in
    "${baseDir}/${dir}";

  userDirectoryDescription =
    dir:
    literalExpression ''
      "''${XDG_RUNTIME_DIR}"/''${dir} on linux or "$(getconf DARWIN_USER_TEMP_DIR)"/''${dir} on darwin.
    '';
in
{
  imports = [
    # See the equivalent note in ./age.nix: the path holds secrets AND templates
    # now, so a name saying "secrets" describes one of its two children.
    (mkRenamedOptionModule [ "age" "secretsMountPoint" ] [ "age" "ageMountPoint" ])
  ];

  options.age = {
    enable = mkEnableOption "agenix" // {
      default = enabledSecrets != [ ] || enabledTemplates != [ ];
      defaultText = literalExpression "enabledSecrets != [ ] || enabledTemplates != [ ]";
    };

    package = mkPackageOption pkgs "age" { };

    verbosity = mkOption {
      type = types.enum [
        "quiet"
        "summary"
        "progress"
        "detailed"
      ];
      default = "detailed";
      description = ''
        Verbosity of agenix activation messages. "quiet" hides routine messages,
        "summary" prints a summary, "progress" also prints installation steps,
        and "detailed" also prints one line per secret. Warnings and errors are always shown.
        This does not affect the agenix command-line tool or other activation output.
      '';
    };

    secrets = mkOption {
      type = types.attrsOf secretType;
      default = { };
      description = ''
        Attrset of secrets.
      '';
    };

    templates = mkOption {
      type = types.attrsOf templateType;
      default = { };
      description = ''
        Attrset of age secret templates to be generated.
      '';
    };

    identityPaths = mkOption {
      type = types.listOf types.path;
      default = [
        "${config.home.homeDirectory}/.ssh/id_ed25519"
        "${config.home.homeDirectory}/.ssh/id_rsa"
      ];
      defaultText = literalExpression ''
        [
          "''${config.home.homeDirectory}/.ssh/id_ed25519"
          "''${config.home.homeDirectory}/.ssh/id_rsa"
        ]
      '';
      description = ''
        Path to SSH keys to be used as identities in age decryption.
      '';
    };

    secretsDir = mkOption {
      type = types.str;
      default = userDirectory "agenix/secrets";
      defaultText = userDirectoryDescription "agenix/secrets";
      description = ''
        Folder where secrets are symlinked to
      '';
    };

    templateDir = mkOption {
      type = types.str;
      default = userDirectory "agenix/templates";
      defaultText = userDirectoryDescription "agenix/templates";
      description = ''
        Folder where rendered templates are symlinked to
      '';
    };

    ageMountPoint = mkOption {
      default = userDirectory "agenix.d";
      defaultText = userDirectoryDescription "agenix.d";
      description = ''
        Where secrets and templates are created before they are symlinked to
        ''${cfg.secretsDir} and ''${cfg.templateDir}.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.identityPaths != [ ];
        message = "age.identityPaths must be set.";
      }
    ];

    systemd.user.services.agenix = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      Unit = {
        Description = "agenix activation";
      };
      Service = {
        Type = "oneshot";
        ExecStart = mountingScript;
      };
      Install.WantedBy = [ "default.target" ];
    };

    launchd.agents.activate-agenix = {
      enable = true;
      config = {
        ProgramArguments = [ mountingScript ];
        KeepAlive = {
          Crashed = false;
          SuccessfulExit = false;
        };
        RunAtLoad = true;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/agenix/stdout";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/agenix/stderr";
      };
    };
  };
}
