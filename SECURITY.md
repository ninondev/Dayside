# Security and privacy

## Report privately

For security or privacy concerns, open this repository's **Security** tab and choose
**Report a vulnerability**. Submit your report through GitHub's private vulnerability
reporting. Keep sensitive details out of public issues and pull requests.

Include the Dayside version, macOS version, steps to reproduce and possible impact.
Remove unrelated personal data from attachments.

## Supported versions

Security fixes are provided for the latest release. If you use an older version,
update and check whether the problem still occurs.

## macOS app data and permissions

This section covers the macOS Release build.

- Dayside runs in the App Sandbox. It stores settings and saved records locally.
- The app makes no direct network requests and does not automatically upload usage or
  diagnostic data. Its Release entitlements grant no network client or server
  permission. Web links open in another application, which may access the internet.
- Calendar access requires permission to read agenda data or add new events.
  Contacts access requires permission to import names. Place suggestions can read
  calendar time zones and contact address cities and country codes when permission
  already exists. Dayside does not modify Contacts.
- Clipboard reads happen when you paste or use the macOS text-conversion service.
  File exports use save dialogs. Calendar export can also create a temporary `.ics`
  file and open it in the default calendar application.
- The app keeps a local diagnostic log and raw MetricKit diagnostic JSON. You can
  export or copy a diagnostic report. Reports include system details and saved
  places; full reports also include settings and logs. Review them before sharing.

Debug builds have additional filesystem and debugging permissions.
