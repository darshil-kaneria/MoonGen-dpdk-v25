-- 0 -> 1 : simple forwarding (0 loss)
Entry{
	RXdev = 0,
	TXdev = 1
}

-- 1 -> 0 : Forward with loss (Gilbert-Elliot) and specify numBufs
Entry{
	RXdev = 1,
	TXdev = 0,
	loss = {0.5, 1, 1, 0},
	RXnumBufs = 2047,
	TXnumBufs = 2047
}
