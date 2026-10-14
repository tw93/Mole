{
  lib,
  buildGo126Module,
}:

let
  fs = lib.fileset;
  goSource = f: f.hasExt "go" && !lib.hasSuffix "_test.go" f.name;
in
buildGo126Module {
  pname = "mole";
  version =
    let
      line = lib.findFirst (lib.hasPrefix "VERSION=") (throw "mole VERSION assignment not found") (
        lib.splitString "\n" (builtins.readFile ./mole)
      );
    in
    builtins.head (builtins.match ''VERSION="([^"]+)"'' line);

  src = fs.toSource {
    root = ./.;
    fileset = fs.unions [
      ./go.mod
      ./go.sum
      # Go sources only; tests are not run (doCheck = false).
      (fs.fileFilter goSource ./cmd)
      (fs.fileFilter goSource ./internal)
      (fs.fileFilter (f: f.hasExt "sh") ./bin)
      ./lib
      ./mole
      ./mo
    ];
  };

  vendorHash = "sha256-PBnWwgH9xYgMwcr/MVbH29Sb4ODI0+lgqSvlYC+pj/0=";

  subPackages = [
    "cmd/analyze"
    "cmd/status"
  ];
  ldflags = [
    "-s"
    "-w"
  ];
  doCheck = false;
  env.CGO_ENABLED = "0";
  # Mole depends on macOS Bash 3.2 and BSD tools at runtime.
  dontPatchShebangs = true;

  postInstall = ''
    mkdir -p $out/share/mole/bin $out/share/mole/lib

    # Relocate compiled Go binaries to the expected internal helper paths
    mv $out/bin/analyze $out/share/mole/bin/analyze-go
    mv $out/bin/status $out/share/mole/bin/status-go

    # Copy scripts and library modules
    cp -r bin/*.sh $out/share/mole/bin/
    cp -r lib/* $out/share/mole/lib/
    cp mole mo $out/share/mole/
    chmod +x $out/share/mole/mole $out/share/mole/mo $out/share/mole/bin/*.sh

    # Pin SCRIPT_DIR so mole reliably finds its lib and bin resources regardless of how it is invoked
    substituteInPlace $out/share/mole/mole \
      --replace-fail 'SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"' "SCRIPT_DIR=\"$out/share/mole\""

    # Symlink user-facing binaries into $out/bin
    ln -sf $out/share/mole/mole $out/bin/mole
    ln -sf $out/share/mole/mo $out/bin/mo
  '';

  meta = {
    description = "Deep clean and optimize your Mac";
    homepage = "https://mole.fit";
    license = lib.licenses.gpl3Only;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    mainProgram = "mole";
  };
}
