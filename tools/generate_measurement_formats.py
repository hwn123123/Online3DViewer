import bpy, sys
from pathlib import Path
out=Path(sys.argv[sys.argv.index('--')+1]);bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
mesh=bpy.data.meshes.new('size100');mesh.from_pydata([(0,0,0),(100,0,0),(100,100,0),(0,100,0)],[],[(0,1,2),(0,2,3)]);mesh.update()
obj=bpy.data.objects.new('size100',mesh);bpy.context.collection.objects.link(obj);bpy.context.view_layer.objects.active=obj;obj.select_set(True)
bpy.context.scene.unit_settings.system='NONE'
bpy.ops.wm.obj_export(filepath=str(out/'size100.obj'),export_materials=False,export_selected_objects=True)
bpy.ops.export_scene.fbx(filepath=str(out/'size100.fbx'),use_selection=True,apply_unit_scale=False,add_leaf_bones=False,axis_forward='-Z',axis_up='Y')
bpy.ops.export_scene.gltf(filepath=str(out/'size100.glb'),export_format='GLB',use_selection=True)
print('generated known-size format fixtures')
