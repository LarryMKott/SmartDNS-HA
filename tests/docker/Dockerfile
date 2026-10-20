FROM debian:12

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      keepalived haproxy procps iproute2 iptables \
      dnsutils net-tools inotify-tools rsync sshpass \
      openssh-server ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

# 容器里没有 systemd：给脚本一个不会挡路的 systemctl 桩
RUN printf '#!/bin/bash\nexit 0\n' > /usr/local/bin/systemctl && chmod +x /usr/local/bin/systemctl

# 双节点互信：允许 root 用密码登录，方便 ssh-copy-id 建立密钥
RUN echo 'root:root' | chpasswd \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && mkdir -p /run/sshd

WORKDIR /opt/dnsha
COPY . /opt/dnsha

CMD ["sleep", "infinity"]
