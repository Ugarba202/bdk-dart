import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

import 'test_constants.dart';

void main() {
  group('Wallet keychains', () {
    test('exposes keychains and public descriptors from Dart', () {
      final descriptor = buildBip84Descriptor(Network.testnet);
      final changeDescriptor = buildBip84ChangeDescriptor(Network.testnet);
      final persister = Persister.newInMemory();
      Wallet? wallet;

      try {
        wallet = Wallet(
          descriptor: descriptor,
          changeDescriptor: changeDescriptor,
          network: Network.testnet,
          persister: persister,
          lookahead: defaultLookahead,
        );

        final keychains = wallet.keychains();

        try {
          expect(keychains, isNotEmpty);
          for (final walletKeychain in keychains) {
            expect(
              wallet.publicDescriptor(keychain: walletKeychain.keychain),
              isNotEmpty,
            );
            expect(walletKeychain.publicDescriptor.toString(), isNotEmpty);
          }
        } finally {
          for (final walletKeychain in keychains) {
            walletKeychain.publicDescriptor.dispose();
          }
        }
      } finally {
        wallet?.dispose();
        persister.dispose();
        descriptor.dispose();
        changeDescriptor.dispose();
      }
    });
  });
}
