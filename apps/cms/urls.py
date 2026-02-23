from django.urls import path
from . import views
 
urlpatterns = [
    path('home-slider/', views.HomeSliderView.as_view(), name='home_slider'),
    path('home-slider/create/', views.HomeSliderCreateView.as_view(), name='home_slider_create'),
    path('home-slider/update/<int:pk>/', views.HomeSliderUpdateView.as_view(), name='home_slider_update'),
    path('home-slider/delete/<int:pk>/', views.HomeSliderDeleteView.as_view(), name='home_slider_delete'),
    path('contacts/', views.ContactFormListView.as_view(), name='contact_list'),
    path('contacts/ajax/', views.contact_form_ajax, name='contact_list_ajax'),
]
