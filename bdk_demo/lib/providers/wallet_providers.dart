import 'package:bdk_demo/models/wallet_record.dart';
import 'package:bdk_demo/services/wallet_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bdk_dart/bdk.dart';
import 'package:uuid/uuid.dart';
import 'settings_providers.dart';

final walletServiceProvider = Provider<WalletService>((ref) {
  final storage = ref.read(storageServiceProvider);
  return WalletService(storage: storage, uuid: const Uuid());
});

final walletDisposerProvider = Provider<WalletDisposer>(
  (ref) =>
      (wallet) => wallet.dispose(),
);

final activeWalletRecordProvider =
    NotifierProvider<ActiveWalletRecordNotifier, WalletRecord?>(
      ActiveWalletRecordNotifier.new,
    );

final activeWalletIdProvider = Provider<String?>((ref) {
  return ref.watch(activeWalletRecordProvider)?.id;
});

class ActiveWalletRecordNotifier extends Notifier<WalletRecord?> {
  @override
  WalletRecord? build() => null;

  void set(WalletRecord record) => state = record;
  void clear() => state = null;
}

final activeWalletProvider = NotifierProvider<ActiveWalletNotifier, Wallet?>(
  ActiveWalletNotifier.new,
);

class ActiveWalletBinding {
  const ActiveWalletBinding({required this.walletId, required this.wallet});

  final String walletId;
  final Wallet wallet;
}

final activeWalletBindingProvider = Provider<ActiveWalletBinding?>((ref) {
  final wallet = ref.watch(activeWalletProvider);
  final walletId = ref.read(activeWalletProvider.notifier).walletId;
  if (wallet == null || walletId == null) return null;
  return ActiveWalletBinding(walletId: walletId, wallet: wallet);
});

class ActiveWalletNotifier extends Notifier<Wallet?> {
  late WalletDisposer _walletDisposer;
  Wallet? _currentWallet;
  String? _currentWalletId;

  String? get walletId => _currentWalletId;

  void _disposeWallet(Wallet? wallet) {
    if (wallet == null) return;
    _walletDisposer(wallet);
  }

  @override
  Wallet? build() {
    _walletDisposer = ref.read(walletDisposerProvider);
    _currentWallet = null;
    _currentWalletId = null;
    ref.onDispose(() => _disposeWallet(_currentWallet));
    return null;
  }

  void set(Wallet wallet, {String? walletId}) {
    final resolvedWalletId = walletId ?? ref.read(activeWalletIdProvider);
    if (identical(_currentWallet, wallet)) {
      _currentWalletId = resolvedWalletId;
      return;
    }
    _disposeWallet(_currentWallet);
    _currentWallet = wallet;
    _currentWalletId = resolvedWalletId;
    state = wallet;
  }

  void replaceWallet(Wallet wallet, {String? walletId}) =>
      set(wallet, walletId: walletId);

  void clear() {
    _disposeWallet(_currentWallet);
    _currentWallet = null;
    _currentWalletId = null;
    state = null;
  }
}

final walletRecordsProvider =
    NotifierProvider<WalletRecordsNotifier, List<WalletRecord>>(
      WalletRecordsNotifier.new,
    );

class WalletRecordsNotifier extends Notifier<List<WalletRecord>> {
  @override
  List<WalletRecord> build() {
    final storage = ref.watch(storageServiceProvider);
    return storage.getWalletRecords();
  }

  Future<void> addWalletRecord(
    WalletRecord record,
    WalletSecrets secrets,
  ) async {
    final storage = ref.read(storageServiceProvider);
    await storage.addWalletRecord(record, secrets);
    state = storage.getWalletRecords();
  }

  Future<void> setFullScanCompleted(String walletId) async {
    final storage = ref.read(storageServiceProvider);
    await storage.setFullScanCompleted(walletId);
    state = storage.getWalletRecords();
  }

  void refresh() {
    state = ref.read(storageServiceProvider).getWalletRecords();
  }
}
