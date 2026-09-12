{
  config,
  pkgs,
  options,
  ...
}:
let
  secret = "hello";
  testScript = pkgs.writeShellApplication {
    name = "agenix-integration";
    text = ''
      grep "${secret}" "${config.age.secrets.system-secret.path}"
      grep "${secret}" "${config.age.secrets.nested-system-secret.path}"
      test ! -L "${config.age.secrets.nested-system-secret.path}"
    '';
  };
in
{
  imports = [
    ./install_ssh_host_keys_darwin.nix
    ../modules/age.nix
  ];

  age = {
    identityPaths = options.age.identityPaths.default ++ [ "/etc/ssh/this_key_wont_exist" ];
    secrets.system-secret.file = ../example/secret1.age;
    # a real file in a nested folder of secretsDir
    secrets.nested-system-secret = {
      file = ../example/secret1.age;
      symlink = false;
      path = "${config.age.secretsDir}/nested/dir/system-secret";
    };
  };

  environment.systemPackages = [ testScript ];

  system.stateVersion = 6;
}
