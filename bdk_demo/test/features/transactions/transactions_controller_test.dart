import 'dart:async';
import 'package:bdk_dart/bdk.dart' as bdk;
import 'package:bdk_demo/features/transactions/models/transaction_history_item.dart';
import 'package:bdk_demo/features/transactions/transactions_controller.dart';
import 'package:bdk_demo/features/transactions/transactions_repository.dart';
import 'package:bdk_demo/models/wallet_record.dart';
import 'package:bdk_demo/providers/wallet_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes/fake_transactions_repository.dart';

class FakeWallet extends Fake implements bdk.Wallet {
  @override
  void dispose() {}
}

class CountingTransactionsRepository implements TransactionsRepository {
  int loadCount = 0;
  List<TransactionHistoryItem> transactions;
  Object? error;

  CountingTransactionsRepository({required this.transactions, this.error});

  @override
  bool isAvailableForWallet(String? walletId) => walletId != null;

  @override
  Future<List<TransactionHistoryItem>> loadTransactions() async {
    loadCount++;
    final currentError = error;
    if (currentError != null) throw currentError;
    return transactions;
  }

  @override
  Future<TransactionHistoryItem?> loadTransactionByTxid(String txid) async {
    if (error != null) throw error!;
    for (final tx in transactions) {
      if (tx.txid == txid) return tx;
    }
    return null;
  }
}

class DelayedTransactionsRepository implements TransactionsRepository {
  final Future<List<TransactionHistoryItem>> delayedResult;

  DelayedTransactionsRepository(this.delayedResult);

  @override
  bool isAvailableForWallet(String? walletId) => walletId != null;

  @override
  Future<List<TransactionHistoryItem>> loadTransactions() async {
    return delayedResult;
  }

  @override
  Future<TransactionHistoryItem?> loadTransactionByTxid(String txid) async {
    final list = await delayedResult;
    for (final tx in list) {
      if (tx.txid == txid) return tx;
    }
    return null;
  }
}

void main() {
  WalletRecord createRecord(String id, String name) {
    return WalletRecord(
      id: id,
      name: name,
      network: WalletNetwork.testnet,
      scriptType: ScriptType.p2wpkh,
    );
  }

  TransactionHistoryItem createTx(String txid, int received) {
    return TransactionHistoryItem(
      txid: txid,
      sent: 0,
      received: received,
      pending: false,
    );
  }

  ProviderContainer createContainer(
    List<Override> overrides, {
    bool overrideWalletBinding = true,
  }) {
    final container = ProviderContainer(
      overrides: [
        ...overrides,
        if (overrideWalletBinding)
          activeWalletBindingProvider.overrideWithValue(
            ActiveWalletBinding(walletId: 'wallet-a', wallet: FakeWallet()),
          ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void keepControllerAlive(ProviderContainer container, String? walletId) {
    final subscription = container.listen(
      transactionsControllerProvider(walletId),
      (_, __) {},
    );
    addTearDown(subscription.close);
  }

  group('TransactionsController & transactionDetailsProvider', () {
    test('no active wallet returns the no-wallet state', () {
      final container = createContainer([]);
      keepControllerAlive(container, null);

      final state = container.read(transactionsControllerProvider(null));
      expect(state.status, TransactionsLoadState.noWallet);
      expect(state.transactions, isEmpty);
    });

    test('an active wallet can load its transaction history', () async {
      final txs = [createTx('tx-1', 5000)];
      final container = createContainer([
        transactionsRepositoryProvider.overrideWithValue(
          FakeTransactionsRepository(transactions: txs),
        ),
      ]);
      keepControllerAlive(container, 'wallet-a');

      await container
          .read(transactionsControllerProvider('wallet-a').notifier)
          .loadTransactions();

      final state = container.read(transactionsControllerProvider('wallet-a'));
      expect(state.status, TransactionsLoadState.success);
      expect(state.transactions, hasLength(1));
      expect(state.transactions.first.txid, 'tx-1');
    });

    test('successful loading clears an old error', () async {
      final repo = CountingTransactionsRepository(
        transactions: [createTx('tx-1', 5000)],
        error: Exception('Initial error'),
      );
      final container = createContainer([
        transactionsRepositoryProvider.overrideWithValue(repo),
      ]);
      keepControllerAlive(container, 'wallet-a');

      final notifier = container.read(
        transactionsControllerProvider('wallet-a').notifier,
      );

      await notifier.loadTransactions();
      var state = container.read(transactionsControllerProvider('wallet-a'));
      expect(state.status, TransactionsLoadState.error);
      expect(state.errorMessage, 'Initial error');

      repo.error = null;
      await notifier.loadTransactions();
      state = container.read(transactionsControllerProvider('wallet-a'));
      expect(state.status, TransactionsLoadState.success);
      expect(state.errorMessage, isNull);
    });

    test('foreground failure produces the error state', () async {
      final repo = CountingTransactionsRepository(
        transactions: [],
        error: Exception('Network failure'),
      );
      final container = createContainer([
        transactionsRepositoryProvider.overrideWithValue(repo),
      ]);
      keepControllerAlive(container, 'wallet-a');

      await container
          .read(transactionsControllerProvider('wallet-a').notifier)
          .loadTransactions();

      final state = container.read(transactionsControllerProvider('wallet-a'));
      expect(state.status, TransactionsLoadState.error);
      expect(state.transactions, isEmpty);
      expect(state.errorMessage, 'Network failure');
    });

    test('background-refresh failure preserves existing rows', () async {
      final repo = CountingTransactionsRepository(
        transactions: [createTx('tx-1', 5000)],
      );
      final container = createContainer([
        transactionsRepositoryProvider.overrideWithValue(repo),
      ]);
      keepControllerAlive(container, 'wallet-a');

      final notifier = container.read(
        transactionsControllerProvider('wallet-a').notifier,
      );
      await notifier.loadTransactions();

      var state = container.read(transactionsControllerProvider('wallet-a'));
      expect(state.status, TransactionsLoadState.success);
      expect(state.transactions, hasLength(1));

      repo.error = Exception('Refresh failed');
      await notifier.loadTransactions(isBackgroundRefresh: true);

      state = container.read(transactionsControllerProvider('wallet-a'));
      expect(state.status, TransactionsLoadState.success);
      expect(state.transactions, hasLength(1));
      expect(state.transactions.first.txid, 'tx-1');
      expect(state.errorMessage, 'Refresh failed');
    });

    test(
      'a refresh requested while another transaction load is running is queued rather than discarded',
      () async {
        final repo = CountingTransactionsRepository(transactions: []);

        final container = createContainer([
          transactionsRepositoryProvider.overrideWith((ref) => repo),
        ]);
        keepControllerAlive(container, 'wallet-a');

        final notifier = container.read(
          transactionsControllerProvider('wallet-a').notifier,
        );

        final load1 = notifier.loadTransactions();
        final load2 = notifier.loadTransactions(isBackgroundRefresh: true);

        await Future.wait([load1, load2]);
        expect(repo.loadCount, 2);
      },
    );

    test(
      'switching the logical active wallet ID from A to B clears A\'s transaction list',
      () async {
        final recordA = createRecord('wallet-a', 'Wallet A');
        final recordB = createRecord('wallet-b', 'Wallet B');

        final txsA = [createTx('tx-a', 10000)];
        final txsB = [createTx('tx-b', 20000)];

        final container = createContainer([
          transactionsRepositoryProvider.overrideWith((ref) {
            final activeId = ref.watch(activeWalletIdProvider);
            return FakeTransactionsRepository(
              transactions: activeId == 'wallet-a' ? txsA : txsB,
            );
          }),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(recordA);
        container.read(activeWalletProvider.notifier).set(FakeWallet());
        final walletAId = container.read(activeWalletIdProvider);
        keepControllerAlive(container, walletAId);

        await container
            .read(transactionsControllerProvider(walletAId).notifier)
            .loadTransactions();
        expect(
          container.read(transactionsControllerProvider(walletAId)).status,
          TransactionsLoadState.success,
        );
        expect(
          container
              .read(transactionsControllerProvider(walletAId))
              .transactions
              .first
              .txid,
          'tx-a',
        );

        container.read(activeWalletRecordProvider.notifier).set(recordB);
        container.read(activeWalletProvider.notifier).set(FakeWallet());
        final walletBId = container.read(activeWalletIdProvider);
        keepControllerAlive(container, walletBId);

        final stateAfterSwitch = container.read(
          transactionsControllerProvider(walletBId),
        );
        expect(stateAfterSwitch.transactions, isEmpty);
      },
    );

    test(
      'an asynchronous result started for wallet A is ignored if the active wallet changes to B before it completes',
      () async {
        final recordA = createRecord('wallet-a', 'Wallet A');
        final recordB = createRecord('wallet-b', 'Wallet B');

        final completer = Completer<List<TransactionHistoryItem>>();
        final delayedRepo = DelayedTransactionsRepository(completer.future);

        final container = createContainer([
          transactionsRepositoryProvider.overrideWithValue(delayedRepo),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(recordA);
        container.read(activeWalletProvider.notifier).set(FakeWallet());
        final walletAId = container.read(activeWalletIdProvider);
        final walletASubscription = container.listen(
          transactionsControllerProvider(walletAId),
          (_, __) {},
        );

        final future = container
            .read(transactionsControllerProvider(walletAId).notifier)
            .loadTransactions();

        container.read(activeWalletRecordProvider.notifier).set(recordB);
        container.read(activeWalletProvider.notifier).set(FakeWallet());
        final walletBId = container.read(activeWalletIdProvider);
        keepControllerAlive(container, walletBId);
        walletASubscription.close();
        await container.pump();

        completer.complete([createTx('tx-a', 10000)]);
        await future;

        final finalState = container.read(
          transactionsControllerProvider(walletBId),
        );
        expect(finalState.transactions, isEmpty);
      },
    );

    test(
      'replacing the FFI Wallet object while retaining the same wallet record ID refreshes data',
      () async {
        final recordA = createRecord('wallet-a', 'Wallet A');

        final wallet1 = FakeWallet();
        final wallet2 = FakeWallet();

        final repo1 = CountingTransactionsRepository(
          transactions: [createTx('tx-a', 10000)],
        );
        final repo2 = CountingTransactionsRepository(
          transactions: [createTx('tx-b', 20000)],
        );

        final container = createContainer([
          transactionsRepositoryProvider.overrideWith((ref) {
            final wallet = ref.watch(activeWalletProvider);
            return identical(wallet, wallet1) ? repo1 : repo2;
          }),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(recordA);
        container.read(activeWalletProvider.notifier).set(wallet1);
        final walletAId = container.read(activeWalletIdProvider);
        keepControllerAlive(container, walletAId);

        await container
            .read(transactionsControllerProvider(walletAId).notifier)
            .loadTransactions();
        expect(
          container
              .read(transactionsControllerProvider(walletAId))
              .transactions
              .single
              .txid,
          'tx-a',
        );

        container.read(activeWalletProvider.notifier).set(wallet2);
        await container.pump();
        await container.pump();

        expect(repo2.loadCount, greaterThan(0));
        expect(
          container
              .read(transactionsControllerProvider(walletAId))
              .transactions
              .single
              .txid,
          'tx-b',
        );
      },
    );

    test(
      'clearing the FFI wallet clears transaction rows while the record remains active',
      () async {
        final record = createRecord('wallet-a', 'Wallet A');
        final wallet = FakeWallet();
        final repo = CountingTransactionsRepository(
          transactions: [createTx('tx-a', 10000)],
        );
        final container = createContainer([
          transactionsRepositoryProvider.overrideWithValue(repo),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(record);
        container.read(activeWalletProvider.notifier).set(wallet);
        keepControllerAlive(container, record.id);

        await container
            .read(transactionsControllerProvider(record.id).notifier)
            .loadTransactions();
        expect(
          container
              .read(transactionsControllerProvider(record.id))
              .transactions,
          isNotEmpty,
        );

        container.read(activeWalletProvider.notifier).clear();
        await container.pump();

        final state = container.read(transactionsControllerProvider(record.id));
        expect(state.status, TransactionsLoadState.noWallet);
        expect(state.transactions, isEmpty);
      },
    );

    test(
      'a stale load failure cannot replace no-wallet state after the wallet is cleared',
      () async {
        final record = createRecord('wallet-a', 'Wallet A');
        final completer = Completer<List<TransactionHistoryItem>>();
        final container = createContainer([
          transactionsRepositoryProvider.overrideWithValue(
            DelayedTransactionsRepository(completer.future),
          ),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(record);
        container.read(activeWalletProvider.notifier).set(FakeWallet());
        keepControllerAlive(container, record.id);
        final load = container
            .read(transactionsControllerProvider(record.id).notifier)
            .loadTransactions();

        container.read(activeWalletProvider.notifier).clear();
        completer.completeError(Exception('stale failure'));
        await load;

        final state = container.read(transactionsControllerProvider(record.id));
        expect(state.status, TransactionsLoadState.noWallet);
        expect(state.transactions, isEmpty);
      },
    );

    test(
      'wallet B data cannot update the controller keyed to wallet A',
      () async {
        final recordA = createRecord('wallet-a', 'Wallet A');
        final recordB = createRecord('wallet-b', 'Wallet B');
        final walletA = FakeWallet();
        final walletB = FakeWallet();
        final repoA = CountingTransactionsRepository(
          transactions: [createTx('tx-a', 10000)],
        );
        final repoB = CountingTransactionsRepository(
          transactions: [createTx('tx-b', 20000)],
        );
        final container = createContainer([
          transactionsRepositoryProvider.overrideWith((ref) {
            final wallet = ref.watch(activeWalletProvider);
            return identical(wallet, walletA) ? repoA : repoB;
          }),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(recordA);
        container.read(activeWalletProvider.notifier).set(walletA);
        keepControllerAlive(container, recordA.id);
        await container
            .read(transactionsControllerProvider(recordA.id).notifier)
            .loadTransactions();

        container.read(activeWalletRecordProvider.notifier).set(recordB);
        container.read(activeWalletProvider.notifier).set(walletB);
        await container.pump();

        final walletAState = container.read(
          transactionsControllerProvider(recordA.id),
        );
        expect(walletAState.status, TransactionsLoadState.noWallet);
        expect(walletAState.transactions, isEmpty);
      },
    );

    test(
      'a transaction detail from wallet A is not reused after switching to wallet B',
      () async {
        final recordA = createRecord('wallet-a', 'Wallet A');
        final recordB = createRecord('wallet-b', 'Wallet B');

        final txA = createTx('tx-123', 10000);
        final txB = createTx('tx-123', 20000);

        final container = createContainer([
          transactionsRepositoryProvider.overrideWith((ref) {
            final activeId = ref.watch(activeWalletIdProvider);
            return FakeTransactionsRepository(
              transactions: activeId == 'wallet-a' ? [txA] : [txB],
            );
          }),
        ], overrideWalletBinding: false);

        container.read(activeWalletRecordProvider.notifier).set(recordA);
        container.read(activeWalletProvider.notifier).set(FakeWallet());

        final detailA = await container.read(
          transactionDetailsProvider((
            walletId: 'wallet-a',
            txid: 'tx-123',
          )).future,
        );
        expect(detailA?.netAmount, 10000);

        container.read(activeWalletRecordProvider.notifier).set(recordB);
        container.read(activeWalletProvider.notifier).set(FakeWallet());

        final detailB = await container.read(
          transactionDetailsProvider((
            walletId: 'wallet-b',
            txid: 'tx-123',
          )).future,
        );
        expect(detailB?.netAmount, 20000);
      },
    );
  });
}
