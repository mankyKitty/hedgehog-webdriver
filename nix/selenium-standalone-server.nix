{ stdenv, fetchurl, makeWrapper, jre, jdk, gcc, xorg
, htmlunit-driver, geckodriver, geckoSupport ? true, chromedriver, chromeSupport ? true }:

with stdenv.lib;

let
  arch = if stdenv.system == "x86_64-linux" then "amd64"
         else if stdenv.system == "i686-linux" then "i386"
         else "";

in stdenv.mkDerivation rec {
  name = "selenium-server-standalone-${version}";
  version = "2.53.0";

  src = fetchurl {
    url = "http://selenium-release.storage.googleapis.com/2.53/selenium-server-standalone-${version}.jar";
    sha256 = "0dp0n5chl1frjy9pcyjvpcdgv1f4dkslh2bpydpxwc5isfzqrf37";
  };

  unpackPhase = "true";

  buildInputs = [ jre makeWrapper ];

  installPhase = ''
    mkdir -p $out/share/lib/${name}
    cp $src $out/share/lib/${name}/${name}.jar
    makeWrapper ${jre}/bin/java $out/bin/selenium-server \
      --add-flags "-cp ${htmlunit-driver}/share/lib/${htmlunit-driver.name}/${htmlunit-driver.name}.jar:$out/share/lib/${name}/${name}.jar" \
      --add-flags ${optionalString chromeSupport "-Dwebdriver.chrome.driver=${chromedriver}/bin/chromedriver"} \
      --add-flags ${optionalString geckoSupport "-Dwebdriver.gecko.driver=${geckodriver}/bin/geckodriver"} \
      --add-flags "org.openqa.grid.selenium.GridLauncher"
  '';

  meta = {
    homepage = https://code.google.com/p/selenium;
    description = "Selenium Server for remote WebDriver";
    maintainers = with maintainers; [ coconnor offline ];
    platforms = platforms.all;
    license = licenses.asl20;
  };
}
