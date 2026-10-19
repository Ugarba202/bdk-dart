import 'package:bdk_demo/core/theme/app_theme.dart';
import 'package:bdk_demo/core/utils/formatters.dart';
import 'package:bdk_demo/features/shared/widgets/secondary_app_bar.dart';
import 'package:bdk_demo/features/shared/widgets/wallet_ui_helpers.dart';
import 'package:bdk_demo/features/transactions/models/transaction_history_item.dart';
import 'package:bdk_demo/features/transactions/transactions_controller.dart';
import 'package:bdk_demo/models/currency_unit.dart';
import 'package:bdk_demo/providers/wallet_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class TransactionsListPage extends ConsumerWidget {
  const TransactionsListPage({super.key});

  void _openTransactionDetail(
    BuildContext context,
    TransactionHistoryItem transaction,
  ) {
    context.pushNamed(
      'transactionDetail',
      pathParameters: {'txid': transaction.txid},
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeWalletId = ref.watch(activeWalletIdProvider);
    final controllerProvider = transactionsControllerProvider(activeWalletId);
    final state = ref.watch(controllerProvider);

    return Scaffold(
      appBar: const SecondaryAppBar(title: 'Transaction History'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _TransactionsBody(state: state, onTap: _openTransactionDetail),
          ],
        ),
      ),
    );
  }
}

class _TransactionsBody extends StatelessWidget {
  final TransactionsState state;
  final void Function(BuildContext context, TransactionHistoryItem transaction)
  onTap;

  const _TransactionsBody({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return switch (state.status) {
      TransactionsLoadState.noWallet => const WalletStateCard(
        icon: Icons.account_balance_wallet_outlined,
        title: 'No active wallet',
        message: 'Create or load a wallet before viewing transaction history.',
      ),
      TransactionsLoadState.idle => WalletStateCard(
        icon: Icons.info_outline,
        title: 'Transaction history not loaded yet',
        message: state.statusMessage,
      ),
      TransactionsLoadState.loading => const WalletStateCard(
        icon: Icons.hourglass_bottom,
        title: 'Loading transaction history...',
        message: 'Reading wallet transactions.',
        showSpinner: true,
      ),
      TransactionsLoadState.error => WalletStateCard(
        icon: Icons.error_outline,
        title: 'Transaction history failed',
        message: state.errorMessage ?? state.statusMessage,
        accentColor: theme.colorScheme.error,
      ),
      TransactionsLoadState.success => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.errorMessage != null) ...[
            WalletStateCard(
              icon: Icons.sync_problem_outlined,
              title: 'Transaction history may be out of date',
              message: state.errorMessage!,
              accentColor: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
          ],
          if (state.transactions.isEmpty)
            const WalletStateCard(
              icon: Icons.history_toggle_off,
              title: 'No transactions yet',
              message:
                  'The active wallet has no transactions yet. Sync the wallet or receive funds to populate history.',
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    for (
                      var index = 0;
                      index < state.transactions.length;
                      index++
                    ) ...[
                      _TransactionRow(
                        transaction: state.transactions[index],
                        onTap: () => onTap(context, state.transactions[index]),
                      ),
                      if (index < state.transactions.length - 1)
                        const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    };
  }
}

class _TransactionRow extends StatelessWidget {
  final TransactionHistoryItem transaction;
  final VoidCallback onTap;

  const _TransactionRow({required this.transaction, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = transaction.netAmount;
    final isIncoming = amount >= 0;
    final accentColor = transaction.pending
        ? theme.colorScheme.secondary
        : isIncoming
        ? Colors.green.shade700
        : theme.colorScheme.primary;
    final amountLabel =
        '${amount >= 0 ? '+' : '-'}${Formatters.formatBalance(amount.abs(), CurrencyUnit.satoshi)}';
    final subtitle = transaction.pending
        ? 'Awaiting confirmation'
        : transaction.blockHeight == null
        ? 'Confirmed'
        : 'Block ${transaction.blockHeight}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      amountLabel,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: accentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  WalletStatusChip(status: transaction.statusLabel),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                transaction.shortTxid,
                style: AppTheme.monoStyle.copyWith(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withAlpha(170),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
