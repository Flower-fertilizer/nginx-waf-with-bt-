#!/bin/bash

# 判断当前用户是否是root用户,root用户UID为0
if [ $(id -u) -ne 0 ]; then
  echo "错误：必须使用root用户执行此脚本！"
  exit 1
fi

# 判断系统是否已安装宝塔面板
if ! command -v bt &> /dev/null; then
  # 如果未安装，则下载和安装宝塔面板
  echo "检测到未安装宝塔面板，正在下载宝塔面板万能安装脚本..."
  if [ -f /usr/bin/curl ]; then
    curl -sSO https://download.bt.cn/install/install_panel.sh
  else
    wget -O install_panel.sh https://download.bt.cn/install/install_panel.sh
  fi

  echo "正在安装宝塔面板，请稍候..."
  bash install_panel.sh ed8484bec

  # 检查安装是否成功
  if command -v bt &> /dev/null; then
    echo "宝塔面板安装成功！将进入下一步：安装所需依赖！"
  else
    echo "错误：宝塔面板安装失败，请检查错误日志！"
    exit 1
  fi
else
  echo "宝塔面板已经安装，将进入下一步：安装所需依赖！"
fi

# 获取系统发行版信息
if command -v lsb_release &> /dev/null; then
  OS=$(lsb_release -si)
elif [ -f /etc/os-release ]; then
  OS=$(awk -F '=' '/^NAME/{print $2}' /etc/os-release | tr -d '"')
else
  echo "错误：无法获取系统发行版信息！"
  exit 1
fi

# 根据系统发行版信息安装ModSecurity和nginx依赖
case $OS in
  Ubuntu|Debian)
    apt update
    apt install -y gcc g++ make build-essential autoconf automake libtool \
        gettext pkg-config libpcre3 libpcre3-dev libxml2 libxml2-dev libcurl4 \
        libgeoip-dev libyajl-dev doxygen zlib1g zlib1g-dev openssl openssl-dev
    ;;
  CentOS|Red\ Hat)
    yum update
    yum install -y gcc-c++ make autoconf automake libtool gettext-devel pcre \
        pcre-devel libxml2 libxml2-devel curl-devel geoip geoip-devel yajl \
        yajl-devel doxygen zlib1g zlib1g-dev openssl openssl-dev
    ;;
  *)
    echo "错误：不支持的系统发行版！"
    exit 1
    ;;
esac
echo "依赖已安装完成！将部署WAF！"

# 测试当前主机与 GitHub 的延迟
if ping -c 3 github.com &> /dev/null; then
  echo "与 GitHub 连接正常，开始安装 ModSecurity..."
else
  echo "与 GitHub 连接不好！请更换 GitHub 源！"
  exit 1
fi

# 判断安装目录是否存在，否则新建，该目录为WAF存储目录
if [ ! -d "/usr/local/src" ]; then
    mkdir /usr/local/src
fi

# 下载、编译并安装 ModSecurity
echo "正在安装WAF..."
cd /usr/local/src
git clone --depth 1 -b v3/master --single-branch https://github.com/SpiderLabs/ModSecurity
cd ModSecurity/
git submodule init         # 初始化子模块
git submodule update       # 更新子模块
./build.sh
./configure
make
make install
echo "安装完成！将进入下一步：检查nginx服务器版本并连接WAF"

# 检查系统是否已经安装了 Nginx
if ! command -v nginx &> /dev/null; then
  # 如果未安装 Nginx，则提示用户输入要安装的 Nginx 版本
  echo "检测到未安装 Nginx，请输入需要安装的 Nginx 版本：（默认为1.22.1版本）"
  read version
  # 如果用户没有输入版本，则默认安装 1.22.1 版本
  if [ -z "$version" ]; then
    version="1.22.1"
  fi
  # 下载指定版本的 Nginx 并解压到 /usr/local/src/ 目录中
  wget -P /usr/local/src/ https://nginx.org/download/nginx-"$version".tar.gz
  tar -xzvf /usr/local/src/nginx-"$version".tar.gz -C /usr/local/src/
else
  # 如果已经安装了 Nginx，则获取当前版本号，并下载相应版本的 Nginx
  current_version=$(nginx -v 2>&1 | grep -oP '(?<=nginx/)[0-9]+\.[0-9]+\.[0-9]+')
  echo "检测到已安装 Nginx，当前版本为 $current_version，将根据已安装版本重新进行编译覆盖安装"
  # 下载当前版本的 Nginx 并解压到 /usr/local/src/ 目录中
  wget -P /usr/local/src/ https://nginx.org/download/nginx-"$current_version".tar.gz
  tar -xzvf /usr/local/src/nginx-"$current_version".tar.gz -C /usr/local/src/
fi
echo "nginx服务器已完成部署！"

echo "开始连接nginx服务器与WAF！"
cd /usr/local/src
git clone --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git
# 获取已安装nginx的版本号
nginx_version=$(nginx -v 2>&1 | awk -F '/' 'NR==1{print $2}')
# 进入对应版本号的目录
cd /usr/local/src/nginx-$nginx_version
./configure --user=www \
--group=www \
--prefix=/www/server/nginx \
--add-module=/www/server/nginx/src/ngx_devel_kit \
--add-module=/www/server/nginx/src/lua_nginx_module \
--add-module=/www/server/nginx/src/ngx_cache_purge \
--add-module=/www/server/nginx/src/nginx-sticky-module \
--with-openssl=/www/server/nginx/src/openssl \
--with-pcre=/www/server/nginx/src/pcre-8.43 \
--with-http_v2_module \
--with-stream \
--with-stream_ssl_module \
--with-stream_ssl_preread_module \
--with-http_stub_status_module \
--with-http_ssl_module \
--with-http_image_filter_module \
--with-http_gzip_static_module \
--with-http_gunzip_module \
--with-ipv6 \
--with-http_sub_module \
--with-http_flv_module \
--with-http_addition_module \
--with-http_realip_module \
--with-http_mp4_module \
--with-ld-opt=-Wl,-E \
--with-cc-opt=-Wno-error \
--with-ld-opt=-ljemalloc \
--with-http_dav_module \
--add-module=/www/server/nginx/src/nginx-dav-ext-module \
--with-http_stub_status_module \
--with-http_ssl_module \
--add-dynamic-module=/usr/local/src/ModSecurity-nginx
make
make modules
make install
echo "已完成编译!开始配置防护策略！"

# 防护策略所需目录检查
modsec_dir="/www/server/nginx/modsec"
if [ ! -d "$modsec_dir" ]; then
  echo "目录不存在，正在创建目录 $modsec_dir"
  mkdir -p "$modsec_dir"
else
  echo "目录已存在: $modsec_dir"
fi
# 导入配置模板
cp /usr/local/src/ModSecurity/modsecurity.conf-recommended /www/server/nginx/modsec/modsecurity.conf
cp /usr/local/src/ModSecurity/unicode.mapping /www/server/nginx/modsec/
echo "正在部署防护策略！"
cd /www/server/nginx/modsec
git clone https://github.com/SpiderLabs/owasp-modsecurity-crs.git
cd owasp-modsecurity-crs
cp crs-setup.conf.example  crs-setup.conf
# 开启规则匹配引擎
sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /www/server/nginx/modsec/modsecurity.conf
# 修改WAF配置文件，导入规则配置文件
echo 'Include ./modsecurity.conf' > /www/server/nginx/modsec/main.conf
echo 'Include ./owasp-modsecurity-crs/crs-setup.conf' >> /www/server/nginx/modsec/main.conf
echo 'Include ./owasp-modsecurity-crs/rules/*.conf' >> /www/server/nginx/modsec/main.conf
echo "防护策略部署完成！开始连接WAF!"

echo "正在连接WAF!"
# 将编译好的模块载入，并引入对应的匹配规则
sed -i "1i\load_module /usr/local/src/nginx-$nginx_version/objs/ngx_http_modsecurity_module.so;" \
    /www/server/nginx/conf/nginx.conf
sed -i '/#include luawaf.conf;/a \ \nmodsecurity on;\nmodsecurity_rules_file /www/server/nginx/modsec/main.conf;' \
    /www/server/nginx/conf/nginx.conf
systemctl restart nginx
echo "连接完成！已开启WAF防护！"

