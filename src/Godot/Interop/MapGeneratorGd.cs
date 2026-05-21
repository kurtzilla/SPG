using Godot;
using SPG.Core;

namespace SPG.Interop;

[GlobalClass]
public partial class MapGeneratorGd : RefCounted
{
	private readonly MapGenerator _generator;

	public MapGeneratorGd(int seed) => _generator = new MapGenerator(seed);

	public void GenerateRegion(GridModelGd grid, int centerX, int centerY, int radius) =>
		_generator.GenerateRegion(grid.Model, centerX, centerY, radius);
}
