FROM --platform=$BUILDPLATFORM perl:5

RUN apt update && apt install -y build-essential libssl-dev zlib1g-dev openssl

RUN groupadd -r matrixmon && useradd --no-log-init -m -g matrixmon matrixmon

RUN mkdir /app

COPY . /app

RUN chown -R matrixmon: /app

USER matrixmon

WORKDIR /app

ENV PATH="/home/matrixmon/perl5/bin${PATH:+:${PATH}}"
ENV PERL5LIB="/home/matrixmon/perl5/lib/perl5${PERL5LIB:+:${PERL5LIB}}"
ENV PERL_LOCAL_LIB_ROOT="/home/matrixmon/perl5${PERL_LOCAL_LIB_ROOT:+:${PERL_LOCAL_LIB_ROOT}}"
ENV PERL_MB_OPT="--install_base \"/home/matrixmon/perl5\""
ENV PERL_MM_OPT="INSTALL_BASE=/home/matrixmon/perl5"
ENV MATRIXMON_CONFIG_PATH="/app/mon.yaml"

RUN ./install-deps.pl

CMD perl mon.pl
