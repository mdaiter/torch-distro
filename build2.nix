
{ pkgs ? import <nixpkgs> {}
, stdenv ? pkgs.stdenv
} :

let

  inherit (pkgs) lib stdenv callPackage writeText readline makeWrapper
    less ncurses cmake openblas coreutils fetchgit libuuid czmq openssl;

  trace = builtins.trace;
  # trace = with lib; const id;

  luapkgs = rec {


    luajit = with pkgs;
      stdenv.mkDerivation rec {
        name    = "luajit-${version}";
        version = "2.1.0-beta1";
        luaversion = "5.1";

        src = fetchurl {
          url    = "http://luajit.org/download/LuaJIT-${version}.tar.gz";
          sha256 = "06170d38387c59d1292001a166e7f5524f5c5deafa8705a49a46fa42905668dd";
        };

        enableParallelBuilding = true;

        patchPhase = ''
          substituteInPlace Makefile \
            --replace /usr/local $out

          substituteInPlace src/Makefile --replace gcc cc
        '' + stdenv.lib.optionalString (stdenv.cc.libc != null)
        ''
          substituteInPlace Makefile \
            --replace ldconfig ${stdenv.cc.libc}/sbin/ldconfig
        '';

        configurePhase = false;
        buildFlags     = [ "amalg" ]; # Build highly optimized version
        installPhase   = ''
          make install INSTALL_INC=$out/include PREFIX=$out
          ln -s $out/bin/luajit* $out/bin/luajit
        '';

        meta = with stdenv.lib; {
          description = "high-performance JIT compiler for Lua 5.1";
          homepage    = http://luajit.org;
          license     = licenses.mit;
          platforms   = platforms.linux ++ platforms.darwin;
          maintainers = [ maintainers.thoughtpolice ];
        };
      };

    buildLuaPackage_ =
      callPackage
        <nixpkgs/pkgs/development/lua-modules/generic>
        ( luajit // { inherit stdenv; } );

    buildLuaPackage = a : buildLuaPackage_ (a//{
      name = "torch-${a.name}";
    });

    luarocks =
      callPackage
        <nixpkgs/pkgs/development/tools/misc/luarocks>
        { lua = luajit; };

    buildLuaRocks = { rockspec ? "", luadeps ? [] , buildInputs ? []
                    , preBuild ? "" , postInstall ? ""
                    , runtimeDeps ? [] ,  ... }@args :
      let

        luadeps_ =
          luadeps ++
          (lib.concatMap (d : if d ? luadeps then d.luadeps else []) luadeps);

        runtimeDeps_ =
          runtimeDeps ++
          (lib.concatMap (d : if d ? runtimeDeps then d.runtimeDeps else []) luadeps) ++
          [ luajit coreutils ];

        mkcfg = ''
          export LUAROCKS_CONFIG=config.lua
          cat >config.lua <<EOF
            rocks_trees = {
                 { name = [[system]], root = [[${luarocks}]] }
               ${lib.concatImapStrings (i : dep :  ", { name = [[dep${toString i}]], root = [[${dep}]] }") luadeps_}
            };

            variables = {
              LUA_BINDIR = "$out/bin";
              LUA_INCDIR = "$out/include";
              LUA_LIBDIR = "$out/lib/lua/${luajit.luaversion}";
            };
          EOF
        '';

      in
      stdenv.mkDerivation (args // {

        inherit preBuild postInstall;

        inherit luadeps runtimeDeps;

        phases = [ "unpackPhase" "patchPhase" "buildPhase"];

        buildInputs = runtimeDeps ++ buildInputs ++ [ makeWrapper luajit ];

        buildPhase = ''
          eval "$preBuild"
          ${mkcfg}
          eval "`${luarocks}/bin/luarocks --deps-mode=all --tree=$out path`"
          ${luarocks}/bin/luarocks make --deps-mode=all --tree=$out ${rockspec}

          for p in $out/bin/*; do
            wrapProgram $p \
              --set LD_LIBRARY_PATH "${lib.makeSearchPath "lib" runtimeDeps_}" \
              --set PATH "${lib.makeSearchPath "bin" runtimeDeps_}" \
              --set LUA_PATH "'$LUA_PATH;$out/share/lua/${luajit.luaversion}/?.lua;$out/share/lua/${luajit.luaversion}/?/init.lua'" \
              --set LUA_CPATH "'$LUA_CPATH;$out/lib/lua/${luajit.luaversion}/?.so;$out/lib/lua/${luajit.luaversion}/?/init.so'"
          done

          eval "$postInstall"
        '';
      });

    # FIXME: doesn't installs lua-files for some reason
    # lua-cjson = buildLuaPackage {
    #   name = "lua-cjson";
    #   src = ./extra/lua-cjson;
    #   rockspec = "lua-cjson-2.1devel-1.rockspec";
    # };

    lua-cjson = stdenv.mkDerivation rec {
      name = "lua-cjson";
      src = ./extra/lua-cjson;

      preConfigure = ''
        makeFlags="PREFIX=$out LUA_LIBRARY=$out/lib/lua"
      '';

      buildInputs = [luajit];

      installPhase = ''
        make install-extra $makeFlags
      '';
    };

    luafilesystem = buildLuaRocks {
      name = "filesystem";
      src = ./extra/luafilesystem;
      luadeps = [lua-cjson];
      rockspec = "rockspecs/luafilesystem-1.6.3-1.rockspec";
    };

    penlight = buildLuaRocks {
      name = "penlight";
      src = ./extra/penlight;
      luadeps = [luafilesystem];
    };

    luaffifb = buildLuaRocks {
      name = "luaffifb";
      src = extra/luaffifb;
    };

    sundown = buildLuaRocks rec {
      name = "sundown";
      src = pkg/sundown;
      rockspec = "rocks/${name}-scm-1.rockspec";
    };

    cwrap = buildLuaRocks rec {
      name = "cwrap";
      src = pkg/cwrap;
      rockspec = "rocks/${name}-scm-1.rockspec";
    };

    paths = buildLuaRocks rec {
      name = "paths";
      src = pkg/paths;
      buildInputs = [cmake];
      rockspec = "rocks/${name}-scm-1.rockspec";
    };

    torch = buildLuaRocks rec {
      name = "torch";
      src = ./pkg/torch;
      luadeps = [ paths cwrap ];
      buildInputs = [ cmake ];
      rockspec = "rocks/${name}-scm-1.rockspec";
      preBuild = ''
        substituteInPlace ${rockspec} \
          --replace '"sys >= 1.0"' ' '
        export LUA_PATH="$src/?.lua;$LUA_PATH"
      '';
    };

    dok = buildLuaRocks rec {
      name = "dok";
      src = ./pkg/dok;
      luadeps = [sundown];
      rockspec = "rocks/${name}-scm-1.rockspec";
    };

    sys = buildLuaRocks rec {
      name = "sys";
      luadeps = [torch];
      buildInputs = [readline cmake];
      src = ./pkg/sys;
      rockspec = "sys-1.1-0.rockspec";
      preBuild = ''
        export Torch_DIR=${torch}/share/cmake/torch
      '';
    };

    xlua = buildLuaRocks rec {
      name = "xlua";
      luadeps = [torch sys];
      src = ./pkg/xlua;
      rockspec = "xlua-1.0-0.rockspec";
    };

    nn = buildLuaRocks rec {
      name = "nn";
      luadeps = [torch luaffifb];
      buildInputs = [cmake];
      src = ./extra/nn;
      rockspec = "rocks/nn-scm-1.rockspec";
      preBuild = ''
        export Torch_DIR=${torch}/share/cmake/torch
      '';
    };

    graph = buildLuaRocks rec {
      name = "graph";
      luadeps = [ torch ];
      buildInputs = [cmake];
      src = ./extra/graph;
      rockspec = "rocks/graph-scm-1.rockspec";
      preBuild = ''
        export Torch_DIR=${torch}/share/cmake/torch
      '';
    };

    nngraph = buildLuaRocks rec {
      name = "nngraph";
      luadeps = [ torch nn graph ];
      buildInputs = [cmake];
      src = ./extra/nngraph;
      preBuild = ''
        export Torch_DIR=${torch}/share/cmake/torch
      '';
    };

    image = buildLuaRocks rec {
      name = "image";
      luadeps = [ torch dok sys xlua ];
      buildInputs = [cmake];
      src = ./pkg/image;
      rockspec = "image-1.1.alpha-0.rockspec";
      preBuild = ''
        export Torch_DIR=${torch}/share/cmake/torch
      '';
    };

    optim = buildLuaRocks rec {
      name = "optim";
      luadeps = [ torch ];
      buildInputs = [cmake];
      src = ./pkg/optim;
      rockspec = "optim-1.0.5-0.rockspec";
      preBuild = ''
        export Torch_DIR=${torch}/share/cmake/torch
      '';
    };

    gnuplot = buildLuaRocks rec {
      name = "gnuplot";
      luadeps = [ torch paths ];
      runtimeDeps = [ pkgs.gnuplot less ];
      src = ./pkg/gnuplot;
      rockspec = "rocks/gnuplot-scm-1.rockspec";
    };

    trepl = buildLuaRocks rec {
      name = "trepl";
      luadeps = [torch gnuplot paths penlight graph nn nngraph image gnuplot optim sys dok];
      runtimeDeps = [ ncurses readline ];
      src = ./exe/trepl;
    };

    lbase64 = buildLuaRocks rec {
      name = "lbase64";
      src = fetchgit {
        url = "https://github.com/LuaDist2/lbase64";
        rev = "1e9e4f1e0bf589a0ed39f58acc185ec5e213d207";
        sha256 = "1i1fpy9v6r4w3lrmz7bmf5ppq65925rv90gx39b3pykfmn0hcb9c";
      };
    };

    luuid = stdenv.mkDerivation rec {
      name = "luuid";
      src = fetchgit {
        url = "https://github.com/LuaDist/luuid";
        # FIXME: set the revision
        #rev = ;
        sha256 = "062gdf1rild11jg46vry93hcbb36b4527pf1dy7q9fv89f7m2nav";
      };

      preConfigure = ''
        cmakeFlags="-DLUA_LIBRARY=${luajit}/lib/lua/${luajit.luaversion} -DINSTALL_CMOD=$out/lib/lua/${luajit.luaversion} -DINSTALL_MOD=$out/lib/lua/${luajit.luaversion}"
      '';

      buildInputs = [cmake libuuid luajit];
    };

    # Doesn't work due to missing deps (according to luarocs).
    itorch = buildLuaRocks rec {
      name = "itorch";
      luadeps = [torch gnuplot paths penlight graph nn nngraph image gnuplot
                  optim sys dok lbase64 lua-cjson luuid];
      buildInputs = [czmq openssl];
      src = ./extra/iTorch;
    };


  };

in

luapkgs

