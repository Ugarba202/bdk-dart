import 'dart:isolate';

import 'package:bdk_dart/bdk.dart' as bdk;
import 'package:bdk_demo/features/transactions/transaction_history_mapper.dart';
import 'package:bdk_demo/features/transactions/transactions_repository.dart';
import 'package:bdk_demo/models/wallet_record.dart';
import 'package:bdk_demo/providers/wallet_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testExtendedPrivKey =
    'tprv8ZgxMBicQKsPf2qfrEygW6fdYseJDDrVnDv26PH5BHdvSuG6ecCbHqLVof9yZcMoM31z9ur3tTYbSnr1WBqbGX97CbXcmp5H6qeMpyvx35B';

class _FakeWallet extends Fake implements bdk.Wallet {
  @override
  void dispose() {}
}

class _LookupWallet extends Fake implements bdk.Wallet {
  _LookupWallet({this.getTxError});

  final Object? getTxError;

  @override
  bdk.CanonicalTx? getTx({required bdk.Txid txid}) {
    final error = getTxError;
    if (error != null) throw error;
    return null;
  }

  @override
  List<bdk.CanonicalTx> transactions() => const [];
}

class _FakeTransactionHistorySource implements TransactionHistorySource {
  _FakeTransactionHistorySource(this.records);

  final List<TransactionHistoryRecord> records;

  @override
  List<TransactionHistoryRecord> transactions() => records;

  @override
  TransactionHistoryRecord? transactionByTxid(String txid) {
    for (final transaction in records) {
      if (transaction.txid == txid) return transaction;
    }
    return null;
  }
}

class _IsolateRecordingTransactionHistorySource
    implements TransactionHistorySource {
  @override
  List<TransactionHistoryRecord> transactions() => [
    TransactionHistoryRecord(
      txid: Isolate.current.debugName ?? 'unnamed-isolate',
      sent: 0,
      received: 1,
      position: const UnconfirmedTransactionPosition(),
    ),
  ];

  @override
  TransactionHistoryRecord? transactionByTxid(String txid) => null;
}

void main() {
  group('WalletTransactionsRepository', () {
    test('binds the production repository to the loaded wallet ID', () {
      const recordA = WalletRecord(
        id: 'wallet-a',
        name: 'Wallet A',
        network: WalletNetwork.testnet,
        scriptType: ScriptType.p2wpkh,
      );
      const recordB = WalletRecord(
        id: 'wallet-b',
        name: 'Wallet B',
        network: WalletNetwork.testnet,
        scriptType: ScriptType.p2wpkh,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(activeWalletRecordProvider.notifier).set(recordA);
      container.read(activeWalletProvider.notifier).set(_FakeWallet());
      final repositoryA = container.read(transactionsRepositoryProvider);
      expect(repositoryA.isAvailableForWallet(recordA.id), isTrue);
      expect(repositoryA.isAvailableForWallet(recordB.id), isFalse);

      container.read(activeWalletRecordProvider.notifier).set(recordB);
      container.read(activeWalletProvider.notifier).set(_FakeWallet());
      final repositoryB = container.read(transactionsRepositoryProvider);
      expect(repositoryB.isAvailableForWallet(recordA.id), isFalse);
      expect(repositoryB.isAvailableForWallet(recordB.id), isTrue);
    });

    test('returns empty history when no active wallet is available', () async {
      final repository = WalletTransactionsRepository(
        walletId: null,
        source: null,
      );

      final transactions = await repository.loadTransactions();

      expect(transactions, isEmpty);
    });

    test('maps wallet transaction records into history items', () async {
      final repository = WalletTransactionsRepository(
        walletId: 'wallet-a',
        source: _FakeTransactionHistorySource([
          const TransactionHistoryRecord(
            txid:
                '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd',
            sent: 1200,
            received: 42000,
            position: ConfirmedTransactionPosition(
              blockHeight: 120,
              confirmationTime: 1704164640,
            ),
          ),
          const TransactionHistoryRecord(
            txid:
                'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
            sent: 1600,
            received: 0,
            position: UnconfirmedTransactionPosition(),
          ),
        ]),
      );

      final transactions = await repository.loadTransactions();

      expect(transactions, hasLength(2));
      expect(transactions.first.txid, startsWith('123456'));
      expect(transactions.first.netAmount, 40800);
      expect(transactions.first.pending, isFalse);
      expect(transactions.first.blockHeight, 120);
      expect(transactions.last.netAmount, -1600);
      expect(transactions.last.pending, isTrue);
    });

    test('loads a transaction detail by txid from wallet records', () async {
      final repository = WalletTransactionsRepository(
        walletId: 'wallet-a',
        source: _FakeTransactionHistorySource([
          const TransactionHistoryRecord(
            txid:
                '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd',
            sent: 0,
            received: 42000,
            position: ConfirmedTransactionPosition(
              blockHeight: 120,
              confirmationTime: 1704164640,
            ),
          ),
        ]),
      );

      final transaction = await repository.loadTransactionByTxid(
        '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd',
      );

      expect(transaction, isNotNull);
      expect(transaction!.received, 42000);
    });

    test('runs full transaction scans outside the UI isolate', () async {
      final repository = WalletTransactionsRepository(
        walletId: 'wallet-a',
        source: _IsolateRecordingTransactionHistorySource(),
      );
      final uiIsolateName = Isolate.current.debugName;

      final transactions = await repository.loadTransactions();

      expect(transactions.single.txid, isNot(uiIsolateName));
    });

    test('scans a real BDK wallet from the background isolate', () async {
      final descriptor = bdk.Descriptor(
        descriptor: 'wpkh($_testExtendedPrivKey/84h/1h/0h/0/*)',
        networkKind: bdk.NetworkKind.test,
      );
      final changeDescriptor = bdk.Descriptor(
        descriptor: 'wpkh($_testExtendedPrivKey/84h/1h/0h/1/*)',
        networkKind: bdk.NetworkKind.test,
      );
      final persister = bdk.Persister.newInMemory();
      final wallet = bdk.Wallet(
        descriptor: descriptor,
        changeDescriptor: changeDescriptor,
        network: bdk.Network.testnet,
        persister: persister,
        lookahead: 25,
      );
      addTearDown(() {
        wallet.dispose();
        persister.dispose();
        descriptor.dispose();
        changeDescriptor.dispose();
      });
      final repository = WalletTransactionsRepository(
        walletId: 'wallet-a',
        source: BdkWalletTransactionSource(wallet),
      );

      final transactions = await repository.loadTransactions();

      expect(transactions, isEmpty);
    });

    test(
      'falls back to a full scan only when direct lookup returns null',
      () async {
        const expectedTxid =
            '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd';
        final repository = WalletTransactionsRepository(
          walletId: 'wallet-a',
          source: _FakeTransactionHistorySource([
            const TransactionHistoryRecord(
              txid: expectedTxid,
              sent: 0,
              received: 42000,
              position: UnconfirmedTransactionPosition(),
            ),
          ]),
        );

        final transaction = await repository.loadTransactionByTxid(
          expectedTxid,
        );

        expect(transaction?.txid, expectedTxid);
      },
    );
  });

  group('BdkWalletTransactionSource', () {
    test('surfaces invalid txid errors', () {
      final source = BdkWalletTransactionSource(_LookupWallet());

      expect(
        () => source.transactionByTxid('not-a-txid'),
        throwsA(isA<bdk.HashParseException>()),
      );
    });

    test('surfaces FFI lookup failures', () {
      final source = BdkWalletTransactionSource(
        _LookupWallet(getTxError: StateError('FFI lookup failed')),
      );

      expect(
        () => source.transactionByTxid('0' * 64),
        throwsA(isA<StateError>()),
      );
    });
  });
}
