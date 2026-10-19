import 'package:bdk_demo/features/transactions/models/transaction_history_item.dart';
import 'package:bdk_demo/features/transactions/transactions_repository.dart';
import 'package:bdk_demo/providers/wallet_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TransactionsLoadState { idle, loading, success, error, noWallet }

class TransactionsState {
  final TransactionsLoadState status;
  final List<TransactionHistoryItem> transactions;
  final String statusMessage;
  final String? errorMessage;

  const TransactionsState({
    required this.status,
    required this.transactions,
    required this.statusMessage,
    this.errorMessage,
  });

  const TransactionsState.idle()
    : status = TransactionsLoadState.idle,
      transactions = const [],
      statusMessage = 'Ready to load transactions.',
      errorMessage = null;

  static const _unset = Object();

  TransactionsState copyWith({
    TransactionsLoadState? status,
    List<TransactionHistoryItem>? transactions,
    String? statusMessage,
    Object? errorMessage = _unset,
  }) {
    return TransactionsState(
      status: status ?? this.status,
      transactions: transactions ?? this.transactions,
      statusMessage: statusMessage ?? this.statusMessage,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

final transactionsControllerProvider = NotifierProvider.autoDispose
    .family<TransactionsController, TransactionsState, String?>(
      TransactionsController.new,
    );

final hasActiveTransactionWalletProvider = Provider<bool>((ref) {
  final walletId = ref.watch(activeWalletIdProvider);
  final binding = ref.watch(activeWalletBindingProvider);
  final repository = ref.watch(transactionsRepositoryProvider);
  return binding?.walletId == walletId &&
      repository.isAvailableForWallet(walletId);
});

final transactionDetailsProvider = FutureProvider.autoDispose
    .family<TransactionHistoryItem?, ({String? walletId, String txid})>((
      ref,
      arg,
    ) {
      final binding = ref.watch(activeWalletBindingProvider);
      final repository = ref.watch(transactionsRepositoryProvider);
      if (binding?.walletId != arg.walletId ||
          !repository.isAvailableForWallet(arg.walletId)) {
        return Future.value(null);
      }
      return repository.loadTransactionByTxid(arg.txid);
    });

class TransactionsController extends Notifier<TransactionsState> {
  TransactionsController(this.walletId);

  final String? walletId;
  Future<void>? _inFlightLoad;
  bool _hasPendingRefresh = false;
  bool _pendingIsBackground = true;

  @override
  TransactionsState build() {
    ref.listen(activeWalletBindingProvider, (previous, next) {
      if (next?.walletId != walletId) {
        state = _noWalletState;
        return;
      }

      final isSuccess = state.status == TransactionsLoadState.success;
      loadTransactions(isBackgroundRefresh: isSuccess);
    });

    final repository = ref.read(transactionsRepositoryProvider);
    if (!_isWalletAvailable(repository)) {
      return _noWalletState;
    }

    Future.microtask(() => loadTransactions());

    return const TransactionsState.idle();
  }

  Future<void> loadTransactions({bool isBackgroundRefresh = false}) async {
    if (!_isWalletAvailable(ref.read(transactionsRepositoryProvider))) {
      state = _noWalletState;
      return;
    }

    if (_inFlightLoad != null) {
      _hasPendingRefresh = true;
      if (!isBackgroundRefresh) {
        _pendingIsBackground = false;
      }
      return _inFlightLoad;
    }

    _inFlightLoad = _performLoad(isBackgroundRefresh: isBackgroundRefresh);
    try {
      await _inFlightLoad;
    } finally {
      _inFlightLoad = null;
      if (ref.mounted && _hasPendingRefresh) {
        final isBg = _pendingIsBackground;
        _hasPendingRefresh = false;
        _pendingIsBackground = true;
        await loadTransactions(isBackgroundRefresh: isBg);
      }
    }
  }

  Future<void> _performLoad({required bool isBackgroundRefresh}) async {
    if (!isBackgroundRefresh) {
      state = state.copyWith(
        status: TransactionsLoadState.loading,
        transactions: const [],
        statusMessage: 'Loading transaction history...',
        errorMessage: null,
      );
    }

    try {
      final repository = ref.read(transactionsRepositoryProvider);
      if (!_isWalletAvailable(repository)) {
        state = _noWalletState;
        return;
      }
      final transactions = await repository.loadTransactions();

      if (!ref.mounted) {
        return;
      }
      if (!_isWalletAvailable(ref.read(transactionsRepositoryProvider))) {
        state = _noWalletState;
        return;
      }

      state = state.copyWith(
        status: TransactionsLoadState.success,
        transactions: transactions,
        statusMessage: transactions.isEmpty
            ? 'Transaction history loaded. No transactions yet.'
            : 'Transaction history loaded.',
        errorMessage: null,
      );
    } catch (error) {
      if (!ref.mounted) {
        return;
      }
      if (!_isWalletAvailable(ref.read(transactionsRepositoryProvider))) {
        state = _noWalletState;
        return;
      }

      if (isBackgroundRefresh &&
          state.status == TransactionsLoadState.success) {
        state = state.copyWith(
          status: TransactionsLoadState.success,
          transactions: state.transactions,
          errorMessage: _readableError(error),
        );
      } else {
        state = state.copyWith(
          status: TransactionsLoadState.error,
          transactions: const [],
          statusMessage: 'Transaction history could not be loaded.',
          errorMessage: _readableError(error),
        );
      }
    }
  }

  String _readableError(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  bool _isWalletAvailable(TransactionsRepository repository) {
    final binding = ref.read(activeWalletBindingProvider);
    return binding?.walletId == walletId &&
        repository.isAvailableForWallet(walletId);
  }

  TransactionsState get _noWalletState => const TransactionsState(
    status: TransactionsLoadState.noWallet,
    transactions: [],
    statusMessage:
        'Create or load a wallet before viewing transaction history.',
  );
}
