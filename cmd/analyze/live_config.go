package main

func nextLiveSortMode(mode liveSortMode) liveSortMode {
	if mode == liveSortContinuous {
		return liveSortFreezeOnMove
	}
	return liveSortContinuous
}

func liveSortModeLabel(mode liveSortMode) string {
	if mode == liveSortFreezeOnMove {
		return "freeze-on-move"
	}
	return "continuous"
}
