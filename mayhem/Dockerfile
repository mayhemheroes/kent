FROM --platform=linux/amd64 ubuntu:22.04 as builder

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libssl-dev libz-dev libpng-dev uuid-dev libmysqlclient-dev

COPY . /repo
ENV MACHTYPE=x86_64
RUN mkdir -p ~/bin/${MACHTYPE}
ENV PATH=$PATH:~/bin/${MACHTYPE}
WORKDIR /repo/src/lib
RUN make -j8
WORKDIR /repo/src/jkOwnLib
RUN make -j8
WORKDIR /repo/src/htslib
RUN make -j8
WORKDIR /repo/src/utils/bamToPsl
RUN make -j8

FROM ubuntu:22.04 as package
COPY --from=builder /root/bin/x86_64/bamToPsl /
