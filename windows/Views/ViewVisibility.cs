using Microsoft.UI.Xaml;

namespace BudgetWarden_Windows.Views;

public static class ViewVisibility
{
    public static Visibility When(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility WhenNot(bool value) =>
        value ? Visibility.Collapsed : Visibility.Visible;
}
