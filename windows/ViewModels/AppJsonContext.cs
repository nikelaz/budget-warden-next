using System.Text.Json.Serialization;

namespace BudgetWarden_Windows.ViewModels;

[JsonSerializable(typeof(string[]))]
internal sealed partial class AppJsonContext : JsonSerializerContext;
