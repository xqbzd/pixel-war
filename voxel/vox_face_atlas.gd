@tool
class_name VoxFaceAtlas
extends RefCounted

## 贴图路线的核心：把每个 cube 单元的 6 个面“投影”成 16x16 贴图，拼成一张图集。
##
## 图集布局：一行 = 一个 cube 单元，一列 = 一个朝向（列序与 VoxMesher.FACES 相同）。
## 因为贴图和体素网格读的是同一份体积，两种部件的配色天然一致，
## 而且一个部件的所有实例共享同一张贴图 + 同一个 mesh —— 这就是“数量很多也不怕”的来源。

const COLS := 6


## 返回 {texture: ImageTexture, image: Image, rows: int, cells: Array}
static func build(volume: VoxVolume, cells: Array) -> Dictionary:
	var rows := cells.size()
	if rows == 0:
		return {"texture": null, "image": null, "rows": 0, "cells": []}
	var unit := VoxVolume.VOXELS_PER_CUBE
	var image := Image.create_empty(COLS * unit, rows * unit, false, Image.FORMAT_RGBA8)
	image.fill(volume.color_of(VoxVolume.EMPTY))
	for r in range(rows):
		var cell: Vector3i = cells[r]
		for f in range(COLS):
			_write_face(image, volume, cell, r, f, VoxMesher.FACES[f])
	return {
		"texture": ImageTexture.create_from_image(image),
		"image": image,
		"rows": rows,
		"cells": cells,
	}


## 图集里某个 (单元行, 朝向列) 的 UV 矩形；留半像素内缩，避免采样到邻格。
static func uv_rect(row: int, col: int, rows: int) -> Rect2:
	var unit := float(VoxVolume.VOXELS_PER_CUBE)
	var w := 1.0 / float(COLS)
	var h := 1.0 / float(rows)
	var inset := Vector2(0.5 / (unit * float(COLS)), 0.5 / (unit * float(rows)))
	var rect := Rect2(Vector2(w * float(col), h * float(row)), Vector2(w, h))
	rect.position += inset
	rect.size -= inset * 2.0
	return rect


static func _write_face(
	image: Image, volume: VoxVolume, cell: Vector3i, row: int, col: int, face: Dictionary
) -> void:
	var n: Vector3i = face["n"]
	var u: Vector3i = face["u"]
	var v: Vector3i = face["v"]
	var d_axis := VoxMesher.axis_of(n)
	var u_axis := VoxMesher.axis_of(u)
	var v_axis := VoxMesher.axis_of(v)
	var positive: bool = n[d_axis] > 0
	var unit := VoxVolume.VOXELS_PER_CUBE
	var base := cell * unit
	var empty_colour := volume.color_of(VoxVolume.EMPTY)
	var origin := Vector2i(col * unit, row * unit)

	for j in range(unit):
		for i in range(unit):
			var vox := base
			vox[u_axis] = base[u_axis] + i
			vox[v_axis] = base[v_axis] + j
			var colour := empty_colour
			# 从外侧往里找第一个实心体素，这就是这个像素看到的表面
			for s in range(unit):
				vox[d_axis] = base[d_axis] + (unit - 1 - s if positive else s)
				var value := volume.get_voxel(vox.x, vox.y, vox.z)
				if value != VoxVolume.EMPTY:
					colour = volume.color_of(value)
					break
			image.set_pixel(origin.x + i, origin.y + j, colour)
