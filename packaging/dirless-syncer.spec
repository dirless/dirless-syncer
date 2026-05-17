Name:     dirless-syncer
Version:  %{pkg_version}
Release:  1
Summary:  Sync AWS IAM Identity Center users to Dirless-enrolled Linux nodes
License:  Apache-2.0
URL:      https://dirless.com
Source0:  dirless-syncer
Source1:  dirless-syncer.service
Source2:  dirless-syncer.example.toml

# Fully static musl binary — no shared library dependencies.
AutoReqProv: no

%description
dirless-syncer syncs users, groups, and memberships from AWS IAM Identity Center
to the Dirless backend. Runs on customer infrastructure — the backend never
reaches into your AWS account.

Requires an EC2 instance with an IAM role granting identitystore:List* and a
node already enrolled via dirless-cli.

%install
install -Dm 0755 %{SOURCE0} %{buildroot}%{_bindir}/dirless-syncer
install -d %{buildroot}%{_sysconfdir}/dirless
install -Dm 0644 %{SOURCE1} %{buildroot}%{_unitdir}/dirless-syncer.service
install -Dm 0644 %{SOURCE2} %{buildroot}%{_docdir}/dirless-syncer/dirless-syncer.example.toml

%files
%{_bindir}/dirless-syncer
%dir %{_sysconfdir}/dirless
%{_unitdir}/dirless-syncer.service
%doc %{_docdir}/dirless-syncer/dirless-syncer.example.toml

%post
systemctl daemon-reload >/dev/null 2>&1 || true

%preun
if [ $1 -eq 0 ]; then
  systemctl --no-reload disable --now dirless-syncer >/dev/null 2>&1 || true
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || true
