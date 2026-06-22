package com.star.viewmodel

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** State for the secondary Outlier window (OutlierWindowView.swift equivalent). */
class OutlierWindowViewModel {
    private val _selectedGroupId = MutableStateFlow<Int?>(null)
    val selectedGroupId: StateFlow<Int?> = _selectedGroupId.asStateFlow()

    private val _showOnlyUndecided = MutableStateFlow(false)
    val showOnlyUndecided: StateFlow<Boolean> = _showOnlyUndecided.asStateFlow()

    fun selectGroup(id: Int?) { _selectedGroupId.value = id }
    fun toggleShowOnlyUndecided() { _showOnlyUndecided.value = !_showOnlyUndecided.value }
}
