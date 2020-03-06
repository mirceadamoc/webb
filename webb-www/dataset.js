/*
	Dataset.
	Written by Cosmin Apreutesei. Public Domain.

	dataset.validators  : {type -> f}
	dataset.converters  : {type -> f}
	dataset.comparators : {type -> f}

	d.fields: [{attr->val}, ...]
		name           :
		type           : for type-based validators and converters.
		client_default : default value that new rows are initialized with.
		server_default : default value that the server sets.
		allow_null     : allow null.
		read_only      : cannot edit.
		validate_value : f(field, v) -> true|err
		validate_row   : f(row) -> true|err
		convert_value  : f(field, s) -> v
		comparator     : f(field) -> f(v1, v2) -> -1|0|1

	d.rows: [{attr->val}, ...]
		values         : [v1,...]
		is_new         : new row, not added on server yet.
		removed        : removed row, not removed on server yet.
		original_values: original values on an updated but not yet saved row.

	^d.value_changed(row, field, val)
	^d.row_added(ri)
	^d.row_removed(ri)

	d.add_row()
	d.remove_row()

*/

let dataset = function(...options) {

	let d = {
		can_add_rows: true,
		can_remove_rows: true,
		can_change_rows: true,
	}

	let fields // [fi: {name:, client_default: v, server_default: v, ...}]
	let rows   // [ri: row]; row = {values: [fi: val], attr: val, ...}
	let field_map = new Map()

	install_events(d)

	let init = function() {

		// set options/override.
		update(d, ...options)

		// add missing state.
		d.validators  = update({}, dataset.validators , d.validators)
		d.converters  = update({}, dataset.converters , d.converters)
		d.comparators = update({}, dataset.comparators, d.comparators)

		d.fields = d.fields || []
		d.rows = d.rows || []

		// init locals.
		fields = d.fields
		rows = d.rows

		for (let i = 0; i < fields.length; i++) {
			let field = fields[i]
			field.index = i
			field_map.set(field.name, field)
		}

	}

	d.field = function(name) {
		return field_map.get(name)
	}

	// get/set row values -----------------------------------------------------

	d.value = function(row, field) {
		let get_value = field.get_value // computed value?
		return get_value ? get_value(field, row, fields) : row.values[field.index]
	}

	d.validate_value = function(field, val) {
		if (val == '' || val == null)
			return field.allow_null || 'NULL not allowed'
		let validate = field.validate || d.validators[field.type]
		if (!validate)
			return true
		return validate.call(d, val, field)
	}

	d.validate_row = return_true // stub

	d.convert_value = function(field, val) {
		let convert = field.convert || d.converters[field.type]
		return convert ? convert.call(d, val, field) : val
	}

	function default_cmp(row1, row2, field_index) {

		// invalid rows come first.
		if (row1.invalid != row2.invalid)
			return row1.invalid ? -1 : 1

		let i1 = row1.invalid[field_index]
		let i2 = row2.invalid[field_index]

		let v1 = row1.values[field_index]
		let v2 = row2.values[field_index]

		// group by data type.
		if (typeof(v1) != typeof(v2))
			return typeof(v1) < typeof(v2) ? -1 : 1

		// NaNs come first.
		if ((v1 !== v1) != (v2 !== v2))
			return v1 !== v1 ? -1 : 1

		return v1 !== v2 ? (v1 < v2 ? -1 : 1) : 0
	}
	d.comparator = function(field) {
		return field.compare || d.comparators[field.type] || default_cmp
	}

	d.can_change_value = function(row, field) {
		return d.can_change_rows && !row.read_only && !field.read_only && !field.get_value
	}

	d.set_value = function(row, field, val) {

		if (!d.can_change_value(row, field))
			return [false, 'read only']

		// convert value to internal represenation.
		val = d.convert_value(field, val)

		// validate converted value.
		let ret = d.validate_value(field, val)
		if (ret !== true)
			return [false, ret]

		// save original values if not already saved and the row is not new.
		if (!row.original_values)
			row.original_values = row.values.slice(0)

		// set the value.
		row.values[field.index] = val

		row.modified = true

		// trigger changed event.
		d.trigger('value_changed', [row, field, val])

		//let ret = d.validate_row(row)
		//row.invalid = ret !== true && ret

		return [true, val]
	}

	// add/remove rows --------------------------------------------------------

	function create_row() {
		let values = []
		// add server_default values or null
		for (let field of fields) {
			let val = field.server_default
			values.push(val != null ? val : null)
		}
		let row = {values: values, is_new: true}
		// set default client values.
		for (let field of fields)
			d.set_value(row, field, field.client_default)
		return row
	}

	d.add_row = function() {
		if (!d.can_add_rows)
			return
		let row = create_row()
		rows.push(row)
		d.trigger('row_added', [row])
		return row
	}

	d.can_remove_row = function(row) {
		if (!d.can_remove_rows)
			return false
		if (row.can_remove === false)
			return false
		return true
	}

	d.remove_row = function(row) {
		if (!d.can_remove_row(row))
			return
		if (row.is_new) {
			rows.remove(rows.indexOf(row))
		} else {
			// mark row as removed
			row.removed = true
		}
		d.trigger('row_removed', [row])
		return row
	}

	// changeset --------------------------------------------------------------

	d.original_value = function(row, field) {
		let values = row.original_values || row.values
		return values[field.index]
	}

	d.value_changed = function(row, field) {
		let t = row.original_values
		return t && t[field.index] !== row.values[field.index]
	}

	// saving

	init()

	return d
}

// validators ----------------------------------------------------------------

dataset.validators = {
	number: function(val, field) {
		val = parseFloat(val)
		return typeof(val) == 'number' && val === val || 'invalid number'
	},
}

dataset.converters = {
	number: function(val, field) {
		if (val == '' || val == null)
			return null
		return parseFloat(val)
	},
	boolean: function(val, field) {
		return !!val
	},
}

dataset.comparators = {

}
