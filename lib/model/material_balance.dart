import 'package:dartchess/dartchess.dart';

/// Textbook piece values in pawns — the only place they live. The engine's
/// view of the position is the eval bar; this answers "am I a piece down?".
const Map<Role, int> pieceValues = {
  Role.pawn: 1,
  Role.knight: 3,
  Role.bishop: 3,
  Role.rook: 5,
  Role.queen: 9,
  Role.king: 0,
};

int valueOf(Role role) => pieceValues[role] ?? 0;

/// Material on the board, White minus Black, in pawns.
int materialBalance(Board board) {
  var balance = 0;
  for (final role in Role.values) {
    balance +=
        valueOf(role) *
        (board.piecesOf(Side.white, role).size -
            board.piecesOf(Side.black, role).size);
  }
  return balance;
}

/// Material from [side]'s point of view: positive = [side] is up.
int materialFor(Board board, Side side) =>
    side == Side.white ? materialBalance(board) : -materialBalance(board);

/// What [side] is ahead by, role for role, most valuable first.
///
/// A difference, not a capture list: equal trades cancel out. Counted from the
/// pieces on the board, so a promoted queen is simply a queen.
List<Role> materialDiff(Board board, Side side) {
  final mine = board.materialCount(side);
  final theirs = board.materialCount(side.opposite);
  final surplus = <Role>[];
  for (final role in rolesByValue) {
    if (role == Role.king) continue;
    final ahead = (mine[role] ?? 0) - (theirs[role] ?? 0);
    for (var i = 0; i < ahead; i++) {
      surplus.add(role);
    }
  }
  return surplus;
}

/// Every role, most valuable first.
final List<Role> rolesByValue = Role.values.toList()
  ..sort((a, b) => valueOf(b).compareTo(valueOf(a)));
