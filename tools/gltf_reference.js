import * as THREE from 'three';
import { GLTFLoader } from '../node_modules/three/examples/jsm/loaders/GLTFLoader.js';

// A separate loader builds the reference scene. Use the same camera, lights and render target.
window.gltfReference = async (url) => {
    const gltf = await new GLTFLoader ().loadAsync (url);
    const root = new THREE.Group ();
    root.rotation.x = Math.PI / 2;
    root.add (gltf.scene);
    root.updateMatrixWorld (true);
    return root;
};
