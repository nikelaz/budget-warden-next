"""Install release credentials in a temporary keychain on a hosted macOS runner."""

import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def credential(name, destination):
    destination.write_bytes(base64.b64decode(os.environ[name], validate=True))
    destination.chmod(0o600)


def main():
    platform = sys.argv[1]
    if platform not in ('ios', 'macos'):
        raise SystemExit('Expected ios or macos.')

    root = Path(os.environ['RUNNER_TEMP']) / 'apple-signing'
    root.mkdir(mode=0o700, exist_ok=True)
    keychain = root / 'release.keychain-db'
    search_list = shlex.split(run('security', 'list-keychains', '-d', 'user').decode())
    (root / 'original-keychains.txt').write_text('\n'.join(search_list))
    password = secrets.token_urlsafe(32)
    run('security', 'create-keychain', '-p', password, str(keychain))
    run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
    run('security', 'unlock-keychain', '-p', password, str(keychain))
    run('security', 'list-keychains', '-d', 'user', '-s', str(keychain), *search_list)

    certificate_names = ['APPLE_DISTRIBUTION_P12_BASE64']
    if platform == 'macos':
        certificate_names.append('MAC_INSTALLER_P12_BASE64')
    for index, name in enumerate(certificate_names):
        certificate = root / f'certificate-{index}.p12'
        credential(name, certificate)
        run('security', 'import', str(certificate), '-P',
            os.environ['APPLE_CERTIFICATE_PASSWORD'], '-A', '-t', 'cert',
            '-f', 'pkcs12', '-k', str(keychain))
        certificate.unlink()
    run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:',
        '-k', password, str(keychain))

    profile_path = root / 'profile.mobileprovision'
    credential('APPLE_PROVISIONING_PROFILE_BASE64', profile_path)
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(profile_path)))
    team = os.environ['APPLE_TEAM_ID']
    bundle = 'com.lazarovco.budgetwarden'
    entitlements = profile['Entitlements']
    app_id = entitlements.get('application-identifier',
                              entitlements.get('com.apple.application-identifier'))
    if team not in profile['TeamIdentifier'] or not app_id or not app_id.endswith('.' + bundle):
        raise SystemExit('The provisioning profile must match the Apple team and app bundle ID.')
    if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise SystemExit('The provisioning profile has expired.')
    if (profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
            or entitlements.get('get-task-allow')
            or entitlements.get('com.apple.security.get-task-allow')):
        raise SystemExit('An App Store distribution profile is required.')
    expected_platform = 'iOS' if platform == 'ios' else 'OSX'
    if expected_platform not in profile.get('Platform', []):
        raise SystemExit(f'The profile must support {expected_platform}.')
    container = 'iCloud.com.lazarovco.BudgetWarden'
    for key in ('com.apple.developer.icloud-container-identifiers',
                'com.apple.developer.ubiquity-container-identifiers'):
        if container not in entitlements.get(key, []):
            raise SystemExit(f'The profile must enable {container} in {key}.')

    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
    identity = next((hashlib.sha1(cert).hexdigest().upper()
                     for cert in profile['DeveloperCertificates']
                     if hashlib.sha1(cert).hexdigest().upper() in identities), None)
    if identity is None:
        raise SystemExit('The profile has no matching signing certificate with a private key in the keychain.')

    uuid = profile['UUID']
    extension = 'mobileprovision' if platform == 'ios' else 'provisionprofile'
    directories = ('Library/MobileDevice/Provisioning Profiles',
                   'Library/Developer/Xcode/UserData/Provisioning Profiles')
    paths = [Path.home() / directory / f'{uuid}.{extension}' for directory in directories]
    (root / 'installed-profiles.json').write_text(json.dumps([str(path) for path in paths]))
    # Support both old and current Xcode provisioning-profile locations.
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(profile_path.read_bytes())

    api_key = root / 'AuthKey.p8'
    api_key.write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'])
    api_key.chmod(0o600)
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f'APPLE_KEYCHAIN={keychain}\n')
        output.write(f'APPLE_SIGNING_IDENTITY={identity}\n')
        output.write(f'APPLE_PROFILE_UUID={uuid}\n')
        output.write(f'APP_STORE_CONNECT_KEY_PATH={api_key}\n')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Do not print commands or credential-tool output, which may contain secrets.
        raise SystemExit(f'Apple credential setup failed in {error.cmd[0]} (exit {error.returncode}).') from None
