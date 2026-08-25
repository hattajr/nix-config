FROM nixos/nix:2.28.0

ENV NIX_CONFIG="experimental-features = nix-command flakes"
ENV HOME=/tmp/home-test
ENV USER=test
ENV LOGNAME=test

COPY validate-home.sh /usr/local/bin/validate-home.sh
RUN chmod 0555 /usr/local/bin/validate-home.sh

ENTRYPOINT ["/usr/local/bin/validate-home.sh"]
