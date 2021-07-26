#!/bin/bash
#--------------------------------------------------------------
#
#  Used add the host to the domain, and enable smartcard login
#      
#  Sources:
#     https://access.redhat.com/solutions/3440441
#     https://access.redhat.com/articles/4253861
#     Other personal scripts related to sssd enrollment
#--------------------------------------------------------------
#---------------------------
#---------------------------
# GLOBAL VARIABLE
#---------------------------
#---------------------------
REALM=<lowercase form of domain>
REALM_UPPER=$(echo ${REALM} | awk '{print toupper($REALM)}')
NAME_SERVER=<used to modify /etc/resolv.conf>
SSSD_PKGS="adcli krb5-workstation oddjob oddjob-mkhomedir realmd sssd sssd-client sssd-tools samba-common-tools"
CAC_PKGS="ccid pam_pkcs11 esc gdm-plugin-smartcard pcsc-lite p11tool ldb-tools openldap-clients gnutls-utils sssd-polkit-rules opensc"
CONFIGS7="/etc/sssd/sssd.conf"
MAJRELEASE=$(cat /etc/redhat-release | awk '{print $7}' | awk -F. '{print $1}')

#these have the potential to change.  Separating for easier adjusting
DOD_SITE="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/"
DOD_FILE="certificates_pkcs7_DoD.zip"
#---------------------------
#---------------------------
# Test for root!!!
#---------------------------
#---------------------------
if [[ $(id -u) -ne 0 ]]; then
   echo "Must be root"
   exit
fi


#---------------------------
#---------------------------
# Verify domain is correct
#---------------------------
#---------------------------
if [[ $(hostname -d) != "${REALM}" ]]; then
   echo "fixing domain name"
   hostnamectl set-hostname "$(hostname -s).${REALM}"
   echo "hostname is now $(hostname)"
   read -p "Is this correct? [y/n]" ANS
   if [[ $ANS != "y" ]]; then
      echo "hostname is incorrect, exiting"
      exit 1
   fi
else
   echo "domain name is correct, moving on"
fi


#---------------------------
#---------------------------
# /etc/resolv.conf might be wrong
#---------------------------
#---------------------------
chattr -i /etc/resolv.conf 2> /dev/null &1>2
sed -i "s/nameserver.*$/nameserver ${NAME_SERVER}/" /etc/resolv.conf
chattr +i /etc/resolv.conf


#---------------------------
#---------------------------
# install and config sssd
#---------------------------
#---------------------------
echo "sssd - packages for sssd"
yum -y -q 0 install ${SSSD_PKGS}

echo "sssd - backing up config files"
cp ${CONFIGS7} ${CONFIGS7}.$(date +%Y%m%d) 2> /dev/null

echo "sssd - configuring config files"
cat > ${CONFIGS7} << EOF
[sssd]
  config_file_version = 2
  debug_level = 3
  domains = ${REALM}
  services = nss, pam, ssh
  default_domain_suffix=${REALM}
  full_name_format = %1\$s

[nss]
  filter_groups      = root
  filter_users         = root
  fallback_homedir = /home/%u
  shell_fallback = /bin/bash
  allowed_shells = /bin/sh,/bin/rbash,/bin/bash
  debug_level = 3
  memcache_timeout = 86400

[pam]
  debug_level = 3
  pam_cert_auth = True
  offline_credentials_expiration = 1

[ssh]
ssh_known_hosts_timeout = 86400

[domain/${REALM}]
  ldap_user_certificate = userCertificate;binary
  ldap_user_name = sAMAccountName
  ad_domain = ${REALM}
  krb5_realm = ${REALM_UPPER}
  realmd_tags = manages-system joined-with-samba
  cache_credentials = True
  id_provider = ad
  krb5_store_password_if_offline = True
  default_shell = /bin/bash
  ldap_id_mapping = True
  use_fully_qualified_names = True
  fallback_homedir = /home/%u
  access_provider = ad
EOF

#enable certificate-based smartcard auth
touch /var/lib/sss/pubconf/pam_preauth_available

echo "sssd - starting and enabling services"
systemctl enable --now sssd oddjobd


#---------------------------
#---------------------------
# install and config sssd
#---------------------------
#---------------------------
for i in $(1..4); echo "";done
echo "Joining domain"
echo ""
read -p 'Username to authenticate with: ' USRNAME
realm join ${REALM_UPPER} -v -U ${USRNAME} 
if [[ $? != 0 ]]; then
   echo "something went wrong!!!! EXITING"
   exit 1
fi


#---------------------------
#---------------------------
# install and config cac
#---------------------------
#---------------------------
yum -y -q 0 install ${CAC_PKGS}

for i in $(1..4); echo "";done
echo "getting the cert zip from DOD DOD Cyber Exchange"
wget -O /tmp/certs.zip ${DOD_SITE}${DOD_FILE}
if [[ $? != 0 ]]; then
   echo "download failed!"
   echo "  1: give local file"
   echo "  2: update URL"
   echo "  *: exit"
   read -p "ANSWER: " ANS
   case ANS in
      1)
         read ANS2
         cp ANS2 /tmp/certs.zip
         if [[ $? != 0 ]]; then
            echo "OOPS.  something went wrong, exiting" && exit 3
         fi
         ;;
      2)
         read ANS2
         wget -O /tmp/certs.zip $ANS2
         if [[ $? != 0 ]]; then
            echo "OOPS.  something went wrong, exiting" && exit 3
         fi
         ;;
      *)
         echo "exiting"
         exit 3
         ;;
   esac
fi

#get certs into a usable format and import them into the nssdb
unzip -d /tmp /tmp/certs.zip
CERT_FILE=$(ls /tmp/Certificates_PKCS7*/*.pem.p7b)
openssl pkcs7 -in ${CERT_FILE} -print_certs -outform DER -out /tmp/all_certs.pem
awk -v RS= '{print > ("/tmp/cert-" NR ".pem")}' /tmp/all_certs.pem
for i in $(ls /tmp/cert*.pem); do 
   certutil -A -d /etc/pki/nssdb -n "$i" -t "TC,C,T" -i /tmp/$i
done

#make sure the system trusts the certs on the domain (unknown if required, but just in case)
cp /tmp/cert*.pem /etc/pki/ca-trust/source/anchors/
update-ca-trust

# cac - minor cleanup
rm -f /tmp/certs.zip /tmp/Certificates_PKCS7_* /tmp/all_certs.pem /tmp/cert*.pem

#---------------------------
#---------------------------
# OPtional, testing CAC read and trust
#---------------------------
#---------------------------
read -p "Would you like to test reading your card, and trust? [y/N]" ANS
if [[ ${ANS} == "y" ]] || [[ ${ANS} == "Y" ]]; then
   pklogin_finder debug
   if [[ $? == "0" ]]; then
      echo "Successful install of CAC abilities"
   else
      echo "Something happened, please debug"
   fi
fi


#---------------------------
#---------------------------
# modifying sshd_config to allow
#---------------------------
#---------------------------
echo "Checking on sshd for cac use"
if [[ $(grep -c "AuthorizedKeysCommand" /etc/ssh/sshd_config) == "0" ]]; then
   echo "sshd does not appear to have cac abailities, adding..."
   echo "AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys" >> /etc/ssh/sshd_config
   echo "AuthorizedKeysCommandUser nobody" >> /etc/ssh/sshd_config
   systemctl restart sshd
else
   echo "sshd is fine, moving on...."
fi

for i in $(1..4); echo "";done
echo "Completed, exiting normally....."
