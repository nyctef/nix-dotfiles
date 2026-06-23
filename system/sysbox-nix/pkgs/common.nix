{ fetchFromGitHub, lib, protobuf, protoc-gen-go, protoc-gen-go-grpc }:

rec {
  version = "0.7.0";

  src = fetchFromGitHub {
    owner = "nestybox";
    repo = "sysbox";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-zcN42LSBxBROPi49gdW+PPuIfnMHVmNhYzuBhs3Nc5U=";
  };

  ldflags = [
    "-X main.edition=Community"
    "-X main.version=v${version}"
    "-X main.commitId=nix-${version}"
    "-X main.builtAt=1970-01-01T00:00:00+00:00"
    "-X main.builtBy=nix"
  ];

  # Generate .pb.go from sibling sysbox-ipc/*.proto. Sysbox doesn't commit
  # generated code; must run before `go mod vendor` so the imports resolve.
  # `modRoot` puts CWD inside one of the three Go modules — go up to repo root.
  protoNativeBuildInputs = [ protobuf protoc-gen-go protoc-gen-go-grpc ];

  protoPreBuild = ''
    pushd ..
    for d in sysbox-ipc/sysboxFsGrpc/sysboxFsProtobuf sysbox-ipc/sysboxMgrGrpc/sysboxMgrProtobuf; do
      ( cd "$d" && protoc \
          --go_out=. --go_opt=paths=source_relative \
          --go-grpc_out=. --go-grpc_opt=paths=source_relative \
          --go-grpc_opt=require_unimplemented_servers=false \
          *.proto )
    done
    popd
  '';

  meta = with lib; {
    homepage = "https://github.com/nestybox/sysbox";
    license = licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    maintainers = [ ];
  };
}
