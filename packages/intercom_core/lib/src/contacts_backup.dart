/// The backup file of the peers and cameras lists (see
/// [IntercomCore.exportContacts] and [IntercomCore.importContacts]).
library;

/// What a backup file says it is, so another JSON file isn't taken for one.
const String contactsFormat = 'gundil-intercom-contacts';

/// What [IntercomCore.importContacts] did.
class ContactsImport {
  const ContactsImport({
    this.peersAdded = 0,
    this.camerasAdded = 0,
    this.skipped = 0,
    this.camerasWithoutLogin = 0,
  });

  final int peersAdded, camerasAdded;

  /// Entries already in the list (or this device itself), left as they are.
  final int skipped;

  /// Added cameras whose passwords weren't in the file: edit them to add
  /// the passwords.
  final int camerasWithoutLogin;

  @override
  String toString() {
    String n(int count, String one, String many) =>
        '$count ${count == 1 ? one : many}';
    return [
      'Added ${n(peersAdded, 'peer', 'peers')} and '
          '${n(camerasAdded, 'camera', 'cameras')}.',
      if (skipped > 0)
        '${n(skipped, 'entry was', 'entries were')} already in the list.',
      if (camerasWithoutLogin > 0)
        '${n(camerasWithoutLogin, 'camera has', 'cameras have')} no password: '
            'edit to add it.',
    ].join(' ');
  }
}
